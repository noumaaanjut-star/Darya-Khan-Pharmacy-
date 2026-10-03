import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DatabaseHelper.instance.database;
  runApp(const JugnooPharmacyApp());
}

class JugnooPharmacyApp extends StatelessWidget {
  const JugnooPharmacyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JUGNOO MEDICAL & DENTAL CENTRE',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.teal,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF6F8FA),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.teal,
          foregroundColor: Colors.white,
          centerTitle: true,
          elevation: 2,
        ),
      ),
      home: const MainDashboardScreen(),
    );
  }
}

// ==========================================
// GOOGLE DRIVE SYNC SERVICE
// ==========================================
class GoogleDriveService {
  static final GoogleDriveService instance = GoogleDriveService._init();
  GoogleDriveService._init();

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [drive.DriveApi.driveAppdataScope],
  );

  GoogleSignInAccount? currentUser;

  Future<bool> signIn() async {
    try {
      currentUser = await _googleSignIn.signIn();
      return currentUser != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> syncDatabaseToDriveSilently(String dbPath) async {
    try {
      currentUser ??= await _googleSignIn.signInSilently();
      if (currentUser == null) return;

      final authHeaders = await currentUser!.authHeaders;
      final authenticateClient = GoogleAuthClient(authHeaders);
      final driveApi = drive.DriveApi(authenticateClient);

      File dbFile = File(dbPath);
      if (!await dbFile.exists()) return;

      var media = drive.Media(dbFile.openRead(), dbFile.lengthSync());

      // Look for existing backup file in appDataFolder
      var fileList = await driveApi.files.list(
        q: "name = 'jugnoo_medical_center.db' and 'appDataFolder' in parents",
        spaces: 'appDataFolder',
      );

      if (fileList.files != null && fileList.files!.isNotEmpty) {
        // Update existing cloud file
        String fileId = fileList.files!.first.id!;
        var driveFile = drive.File();
        await driveApi.files.update(driveFile, fileId, uploadMedia: media);
      } else {
        // Upload new file
        var driveFile = drive.File()
          ..name = 'jugnoo_medical_center.db'
          ..parents = ['appDataFolder'];
        await driveApi.files.create(driveFile, uploadMedia: media);
      }
    } catch (_) {
      // Offline or sync failure handled gracefully without interrupting user
    }
  }
}

class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();

  GoogleAuthClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _client.send(request);
  }
}

// ==========================================
// 1. LOCAL DATABASE HELPER (SQLite)
// ==========================================
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('jugnoo_medical_center.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 3,
      onCreate: _createDB,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE sales ADD COLUMN unitPrice REAL DEFAULT 0.0');
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE sales ADD COLUMN invoiceId INTEGER DEFAULT 0');
        }
      },
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE inventory (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        brandName TEXT NOT NULL,
        genericName TEXT NOT NULL,
        unitPrice REAL NOT NULL,
        packPrice REAL NOT NULL,
        expiryDate TEXT NOT NULL,
        quantity INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE sales (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        invoiceId INTEGER NOT NULL,
        medicineId INTEGER NOT NULL,
        brandName TEXT NOT NULL,
        quantitySold INTEGER NOT NULL,
        unitPrice REAL NOT NULL,
        totalAmount REAL NOT NULL,
        saleDate TEXT NOT NULL
      )
    ''');
  }

  Future<int> addMedicine(Map<String, dynamic> row) async {
    final db = await instance.database;
    int id = await db.insert('inventory', row);
    _triggerDriveSync();
    return id;
  }

  Future<List<Map<String, dynamic>>> getAllMedicines() async {
    final db = await instance.database;
    return await db.query('inventory', orderBy: 'brandName ASC');
  }

  Future<int> updateMedicine(int id, Map<String, dynamic> row) async {
    final db = await instance.database;
    int count = await db.update('inventory', row, where: 'id = ?', whereArgs: [id]);
    _triggerDriveSync();
    return count;
  }

  Future<bool> processMultiItemSale(List<Map<String, dynamic>> cartItems) async {
    final db = await instance.database;
    
    for (var item in cartItems) {
      final res = await db.query('inventory', where: 'id = ?', whereArgs: [item['id']]);
      if (res.isEmpty) return false;
      int currentQty = res.first['quantity'] as int;
      if (currentQty < (item['cartQty'] as int)) return false;
    }

    int newInvoiceId = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      String nowStr = DateTime.now().toIso8601String();
      for (var item in cartItems) {
        int medId = item['id'];
        int qtySold = item['cartQty'];
        double uPrice = (item['unitPrice'] as num).toDouble();
        double total = uPrice * qtySold;

        await txn.rawUpdate(
          'UPDATE inventory SET quantity = quantity - ? WHERE id = ?',
          [qtySold, medId],
        );

        await txn.insert('sales', {
          'invoiceId': newInvoiceId,
          'medicineId': medId,
          'brandName': item['brandName'],
          'quantitySold': qtySold,
          'unitPrice': uPrice,
          'totalAmount': total,
          'saleDate': nowStr,
        });
      }
    });

    _triggerDriveSync();
    return true;
  }

  void _triggerDriveSync() async {
    final dbPath = await getDatabasesPath();
    final fullPath = p.join(dbPath, 'jugnoo_medical_center.db');
    GoogleDriveService.instance.syncDatabaseToDriveSilently(fullPath);
  }

  Future<List<Map<String, dynamic>>> getDetailedSales(DateTime date, {bool isMonthly = false}) async {
    final db = await instance.database;
    String start, end;

    if (isMonthly) {
      start = DateTime(date.year, date.month, 1).toIso8601String();
      end = DateTime(date.year, date.month + 1, 0, 23, 59, 59).toIso8601String();
    } else {
      start = DateTime(date.year, date.month, date.day).toIso8601String();
      end = DateTime(date.year, date.month, date.day, 23, 59, 59).toIso8601String();
    }

    return await db.query(
      'sales',
      where: 'saleDate BETWEEN ? AND ?',
      whereArgs: [start, end],
      orderBy: 'saleDate DESC',
    );
  }
}

// ==========================================
// 2. MAIN DASHBOARD SCREEN
// ==========================================
class MainDashboardScreen extends StatefulWidget {
  const MainDashboardScreen({super.key});

  @override
  State<MainDashboardScreen> createState() => _MainDashboardScreenState();
}

class _MainDashboardScreenState extends State<MainDashboardScreen> {
  int _currentIndex = 0;

  final List<Widget> _pages = const [
    InventoryTab(),
    POSBillingTab(),
    SalesReportsTab(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('JUGNOO MEDICAL & DENTAL CENTRE'),
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_sync),
            tooltip: 'Google Drive Account',
            onPressed: () async {
              bool success = await GoogleDriveService.instance.signIn();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(success ? 'Google Drive Connected for Auto-Sync!' : 'Google Drive Sign-In Failed/Cancelled'),
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: _pages[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        selectedItemColor: Colors.teal,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.inventory_2), label: 'Stock Inventory'),
          BottomNavigationBarItem(icon: Icon(Icons.point_of_sale), label: 'POS Billing'),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: 'Sales Report'),
        ],
      ),
    );
  }
}

// ==========================================
// 3. INVENTORY MANAGEMENT TAB
// ==========================================
class InventoryTab extends StatefulWidget {
  const InventoryTab({super.key});

  @override
  State<InventoryTab> createState() => _InventoryTabState();
}

class _InventoryTabState extends State<InventoryTab> {
  List<Map<String, dynamic>> _medicines = [];
  List<Map<String, dynamic>> _filteredMedicines = [];
  TextEditingController searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refreshInventory();
  }

  void _refreshInventory() async {
    final data = await DatabaseHelper.instance.getAllMedicines();
    setState(() {
      _medicines = data;
      _filteredMedicines = data;
    });
  }

  void _filterSearch(String query) {
    setState(() {
      _filteredMedicines = _medicines.where((med) {
        final bName = med['brandName'].toString().toLowerCase();
        final gName = med['genericName'].toString().toLowerCase();
        return bName.contains(query.toLowerCase()) || gName.contains(query.toLowerCase());
      }).toList();
    });
  }

  bool _isLowStock(int qty) => qty <= 10;

  bool _isNearExpiry(String expiryStr) {
    try {
      DateTime expiry = DateFormat('yyyy-MM-dd').parse(expiryStr);
      DateTime warningThreshold = DateTime.now().add(const Duration(days: 90));
      return expiry.isBefore(warningThreshold);
    } catch (_) {
      return false;
    }
  }

  void _openAddEditModal({Map<String, dynamic>? item}) {
    final brandCtrl = TextEditingController(text: item?['brandName'] ?? '');
    final genericCtrl = TextEditingController(text: item?['genericName'] ?? '');
    final unitPriceCtrl = TextEditingController(text: item?['unitPrice']?.toString() ?? '');
    final packPriceCtrl = TextEditingController(text: item?['packPrice']?.toString() ?? '');
    final expiryCtrl = TextEditingController(text: item?['expiryDate'] ?? '');
    final qtyCtrl = TextEditingController(text: item?['quantity']?.toString() ?? '');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          left: 16,
          right: 16,
          top: 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                item == null ? 'Add New Medicine' : 'Edit Medicine Stock',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.teal),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: brandCtrl,
                decoration: const InputDecoration(labelText: 'Brand Name (e.g. Panadol)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: genericCtrl,
                decoration: const InputDecoration(labelText: 'Generic Name (e.g. Paracetamol)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: unitPriceCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Unit Price (Rs)', border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: packPriceCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Pack Price (Rs)', border: OutlineInputBorder()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: qtyCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Quantity', border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: expiryCtrl,
                      readOnly: true,
                      decoration: const InputDecoration(labelText: 'Expiry Date', border: OutlineInputBorder()),
                      onTap: () async {
                        DateTime? picked = await showDatePicker(
                          context: context,
                          initialDate: DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2035),
                        );
                        if (picked != null) {
                          expiryCtrl.text = DateFormat('yyyy-MM-dd').format(picked);
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  minimumSize: const Size.fromHeight(50),
                ),
                onPressed: () async {
                  if (brandCtrl.text.isEmpty || qtyCtrl.text.isEmpty) return;

                  Map<String, dynamic> row = {
                    'brandName': brandCtrl.text.trim(),
                    'genericName': genericCtrl.text.trim(),
                    'unitPrice': double.tryParse(unitPriceCtrl.text) ?? 0.0,
                    'packPrice': double.tryParse(packPriceCtrl.text) ?? 0.0,
                    'expiryDate': expiryCtrl.text.isEmpty ? '2026-12-31' : expiryCtrl.text,
                    'quantity': int.tryParse(qtyCtrl.text) ?? 0,
                  };

                  if (item == null) {
                    await DatabaseHelper.instance.addMedicine(row);
                  } else {
                    await DatabaseHelper.instance.updateMedicine(item['id'], row);
                  }

                  if (mounted) {
                    Navigator.pop(context);
                    _refreshInventory();
                  }
                },
                child: Text(
                  item == null ? 'Save Stock' : 'Update Stock',
                  style: const TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: TextField(
              controller: searchController,
              onChanged: _filterSearch,
              decoration: InputDecoration(
                hintText: 'Search by Brand or Generic name...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                filled: true,
                fillColor: Colors.white,
              ),
            ),
          ),
          Expanded(
            child: _filteredMedicines.isEmpty
                ? const Center(child: Text('No medicines found in inventory.'))
                : ListView.builder(
                    itemCount: _filteredMedicines.length,
                    itemBuilder: (ctx, idx) {
                      final item = _filteredMedicines[idx];
                      bool lowStock = _isLowStock(item['quantity']);
                      bool nearExpiry = _isNearExpiry(item['expiryDate']);

                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: ListTile(
                          title: Text(
                            item['brandName'],
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Generic: ${item['genericName']}'),
                              Text('Unit: Rs. ${item['unitPrice']} | Pack: Rs. ${item['packPrice']}'),
                              Text('Expiry: ${item['expiryDate']}'),
                            ],
                          ),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '${item['quantity']} in stock',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: lowStock ? Colors.red : Colors.black87,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (lowStock)
                                    const Tooltip(message: 'Low Stock Alert', child: Icon(Icons.warning, color: Colors.orange, size: 20)),
                                  if (nearExpiry)
                                    const Tooltip(message: 'Near Expiry Alert', child: Icon(Icons.event_busy, color: Colors.red, size: 20)),
                                  IconButton(
                                    icon: const Icon(Icons.edit, size: 20, color: Colors.teal),
                                    onPressed: () => _openAddEditModal(item: item),
                                  ),
                                ],
                              )
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.teal,
        onPressed: () => _openAddEditModal(),
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}

// ==========================================
// 4. POS BILLING TAB & PRINTING HELPERS
// ==========================================
class POSBillingTab extends StatefulWidget {
  const POSBillingTab({super.key});

  @override
  State<POSBillingTab> createState() => _POSBillingTabState();
}

class _POSBillingTabState extends State<POSBillingTab> {
  List<Map<String, dynamic>> _allMedicines = [];
  final List<Map<String, dynamic>> _cart = [];

  @override
  void initState() {
    super.initState();
    _loadMedicines();
  }

  void _loadMedicines() async {
    final data = await DatabaseHelper.instance.getAllMedicines();
    setState(() {
      _allMedicines = data;
    });
  }

  double get _grandTotal {
    double total = 0.0;
    for (var item in _cart) {
      double price = (item['unitPrice'] as num).toDouble();
      int qty = item['cartQty'] as int;
      total += (price * qty);
    }
    return total;
  }

  void _addToCart(Map<String, dynamic> medicine) {
    int existingIdx = _cart.indexWhere((element) => element['id'] == medicine['id']);
    if (existingIdx != -1) {
      int currentCartQty = _cart[existingIdx]['cartQty'];
      if (currentCartQty < medicine['quantity']) {
        setState(() {
          _cart[existingIdx]['cartQty'] += 1;
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot add more than available stock!')),
        );
      }
    } else {
      if (medicine['quantity'] > 0) {
        setState(() {
          Map<String, dynamic> newItem = Map.from(medicine);
          newItem['cartQty'] = 1;
          _cart.add(newItem);
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Medicine is out of stock!')),
        );
      }
    }
  }

  void _updateCartQty(int index, int delta) {
    int currentQty = _cart[index]['cartQty'];
    int stockQty = _cart[index]['quantity'];
    int newQty = currentQty + delta;

    if (newQty <= 0) {
      setState(() {
        _cart.removeAt(index);
      });
    } else if (newQty <= stockQty) {
      setState(() {
        _cart[index]['cartQty'] = newQty;
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Maximum available stock reached!')),
      );
    }
  }

  Future<void> _printReceipt(List<Map<String, dynamic>> items, double total) async {
    final pdf = pw.Document();
    final dateStr = DateFormat('dd-MMM-yyyy hh:mm a').format(DateTime.now());

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80,
        margin: const pw.EdgeInsets.all(10),
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Center(
                child: pw.Text(
                  'JUGNOO MEDICAL & DENTAL CENTRE',
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 13),
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Center(
                child: pw.Text('POS Receipt | $dateStr', style: const pw.TextStyle(fontSize: 8)),
              ),
              pw.Divider(thickness: 0.8),
              pw.SizedBox(height: 4),
              
              ...items.map((item) {
                double uPrice = (item['unitPrice'] as num).toDouble();
                int qty = item['cartQty'] ?? item['quantitySold'] ?? 1;
                double lTotal = uPrice * qty;
                return pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 2),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Expanded(
                        child: pw.Text('${item['brandName']} (${qty}x)', style: const pw.TextStyle(fontSize: 9)),
                      ),
                      pw.Text('Rs. ${lTotal.toStringAsFixed(0)}', style: const pw.TextStyle(fontSize: 9)),
                    ],
                  ),
                );
              }).toList(),

              pw.Divider(thickness: 0.8),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Total Payable:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11)),
                  pw.Text('Rs. ${total.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11)),
                ],
              ),
              pw.SizedBox(height: 12),
              pw.Divider(thickness: 0.5),
              
              pw.Center(
                child: pw.Text('Phone: 0325-1723777', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8)),
              ),
              pw.SizedBox(height: 2),
              pw.Center(
                child: pw.Text(
                  'Address: 01, Main Ghazi Road, ALLA\' ABAD, WESTRIDGE 3',
                  textAlign: pw.TextAlign.center,
                  style: const pw.TextStyle(fontSize: 7),
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Center(
                child: pw.Text('Get Well Soon!', style: pw.TextStyle(fontStyle: pw.FontStyle.italic, fontSize: 8)),
              ),
            ],
          );
        },
      ),
    );

    await Printing.layoutPdf(onLayout: (PdfPageFormat format) async => pdf.save());
  }

  void _openSearchDialog() {
    String searchKeyword = '';
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final filtered = _allMedicines.where((med) {
              final brand = med['brandName'].toString().toLowerCase();
              final generic = med['genericName'].toString().toLowerCase();
              return brand.contains(searchKeyword.toLowerCase()) || generic.contains(searchKeyword.toLowerCase());
            }).toList();

            return AlertDialog(
              title: const Text('Add Items to Cart'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'Search by brand or generic...',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (val) {
                        setDialogState(() {
                          searchKeyword = val;
                        });
                      },
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(child: Text('No matching medicine found.'))
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: filtered.length,
                              itemBuilder: (ctx, idx) {
                                final med = filtered[idx];
                                return ListTile(
                                  title: Text(med['brandName'], style: const TextStyle(fontWeight: FontWeight.bold)),
                                  subtitle: Text('${med['genericName']} | Unit: Rs. ${med['unitPrice']}'),
                                  trailing: ElevatedButton(
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
                                    onPressed: () {
                                      _addToCart(med);
                                      Navigator.pop(context);
                                    },
                                    child: const Text('Add', style: TextStyle(color: Colors.white)),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.teal,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.add_shopping_cart, color: Colors.white),
              label: const Text('Search & Add Items to Bill', style: TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.bold)),
              onPressed: _openSearchDialog,
            ),
          ),
          
          Expanded(
            child: _cart.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.shopping_cart_outlined, size: 64, color: Colors.grey),
                        SizedBox(height: 8),
                        Text('No medicines added to bill yet.', style: TextStyle(color: Colors.grey, fontSize: 16)),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _cart.length,
                    itemBuilder: (ctx, idx) {
                      final item = _cart[idx];
                      double unitPrice = (item['unitPrice'] as num).toDouble();
                      int cartQty = item['cartQty'];
                      double lineTotal = unitPrice * cartQty;

                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(item['brandName'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                    Text('Rs. $unitPrice each | Stock: ${item['quantity']}'),
                                  ],
                                ),
                              ),
                              Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                                    onPressed: () => _updateCartQty(idx, -1),
                                  ),
                                  Text('$cartQty', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                  IconButton(
                                    icon: const Icon(Icons.add_circle_outline, color: Colors.teal),
                                    onPressed: () => _updateCartQty(idx, 1),
                                  ),
                                ],
                              ),
                              SizedBox(
                                width: 70,
                                child: Text(
                                  'Rs. ${lineTotal.toStringAsFixed(0)}',
                                  textAlign: TextAlign.end,
                                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.teal),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),

          Card(
            margin: const EdgeInsets.all(12),
            elevation: 3,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Total Bill Amount:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      Text('Rs. ${_grandTotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.teal)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(50),
                            side: const BorderSide(color: Colors.teal, width: 1.5),
                          ),
                          icon: const Icon(Icons.print, color: Colors.teal),
                          label: const Text('Print Receipt', style: TextStyle(fontSize: 16, color: Colors.teal, fontWeight: FontWeight.bold)),
                          onPressed: _cart.isEmpty ? null : () => _printReceipt(List.from(_cart), _grandTotal),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.teal,
                            minimumSize: const Size.fromHeight(50),
                          ),
                          onPressed: _cart.isEmpty
                              ? null
                              : () async {
                                  List<Map<String, dynamic>> printCopy = List.from(_cart);
                                  double printTotal = _grandTotal;

                                  bool success = await DatabaseHelper.instance.processMultiItemSale(_cart);
                                  if (success) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Sale completed & stock updated!')),
                                    );
                                    
                                    await _printReceipt(printCopy, printTotal);

                                    setState(() {
                                      _cart.clear();
                                    });
                                    _loadMedicines();
                                  } else {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Error processing sale! Check stock.'), backgroundColor: Colors.red),
                                    );
                                  }
                                },
                          child: const Text('Complete Sale', style: TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// 5. GROUPED & ITEMIZED SALES REPORTS TAB
// ==========================================
class SalesReportsTab extends StatefulWidget {
  const SalesReportsTab({super.key});

  @override
  State<SalesReportsTab> createState() => _SalesReportsTabState();
}

class _SalesReportsTabState extends State<SalesReportsTab> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<Map<String, dynamic>> _rawDailySales = [];
  List<Map<String, dynamic>> _rawMonthlySales = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadSalesData();
  }

  void _loadSalesData() async {
    DateTime now = DateTime.now();
    final dailyData = await DatabaseHelper.instance.getDetailedSales(now, isMonthly: false);
    final monthlyData = await DatabaseHelper.instance.getDetailedSales(now, isMonthly: true);

    setState(() {
      _rawDailySales = dailyData;
      _rawMonthlySales = monthlyData;
    });
  }

  List<Map<String, dynamic>> _groupDailyByInvoice(List<Map<String, dynamic>> raw) {
    Map<String, List<Map<String, dynamic>>> grouped = {};
    for (var row in raw) {
      String key = row['invoiceId'] != null && row['invoiceId'] != 0
          ? row['invoiceId'].toString()
          : row['saleDate'].toString();
      if (!grouped.containsKey(key)) {
        grouped[key] = [];
      }
      grouped[key]!.add(row);
    }

    List<Map<String, dynamic>> invoices = [];
    grouped.forEach((key, items) {
      double total = items.fold(0.0, (sum, i) => sum + (i['totalAmount'] as num).toDouble());
      DateTime dt = DateTime.parse(items.first['saleDate']);
      invoices.add({
        'invoiceId': key,
        'date': dt,
        'totalAmount': total,
        'items': items,
      });
    });

    invoices.sort((a, b) => (b['date'] as DateTime).compareTo(a['date'] as DateTime));
    return invoices;
  }

  List<Map<String, dynamic>> _groupMonthlyByItemDate(List<Map<String, dynamic>> raw) {
    Map<String, Map<String, dynamic>> aggregated = {};

    for (var row in raw) {
      DateTime dt = DateTime.parse(row['saleDate']);
      String dateKey = DateFormat('MMM dd, yyyy').format(dt);
      String brand = row['brandName'];
      String compositeKey = '$dateKey|$brand';

      if (!aggregated.containsKey(compositeKey)) {
        aggregated[compositeKey] = {
          'dateStr': dateKey,
          'brandName': brand,
          'totalQty': 0,
          'totalAmount': 0.0,
          'unitPrice': (row['unitPrice'] as num).toDouble(),
          'rawDate': dt,
        };
      }

      aggregated[compositeKey]!['totalQty'] = (aggregated[compositeKey]!['totalQty'] as int) + (row['quantitySold'] as int);
      aggregated[compositeKey]!['totalAmount'] = (aggregated[compositeKey]!['totalAmount'] as double) + ((row['totalAmount'] as num).toDouble());
    }

    List<Map<String, dynamic>> result = aggregated.values.toList();
    result.sort((a, b) {
      int dateComp = (b['rawDate'] as DateTime).compareTo(a['rawDate'] as DateTime);
      if (dateComp != 0) return dateComp;
      return (a['brandName'] as String).compareTo(b['brandName'] as String);
    });

    return result;
  }

  @override
  Widget build(BuildContext context) {
    double dailyTotal = _rawDailySales.fold(0.0, (sum, i) => sum + (i['totalAmount'] as num).toDouble());
    double monthlyTotal = _rawMonthlySales.fold(0.0, (sum, i) => sum + (i['totalAmount'] as num).toDouble());

    List<Map<String, dynamic>> groupedInvoices = _groupDailyByInvoice(_rawDailySales);
    List<Map<String, dynamic>> aggregatedMonthly = _groupMonthlyByItemDate(_rawMonthlySales);

    return Column(
      children: [
        TabBar(
          controller: _tabController,
          labelColor: Colors.teal,
          unselectedLabelColor: Colors.grey,
          indicatorColor: Colors.teal,
          tabs: const [
            Tab(icon: Icon(Icons.receipt_long), text: 'Today\'s Sales'),
            Tab(icon: Icon(Icons.calendar_month), text: 'Monthly History'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              Column(
                children: [
                  Container(
                    width: double.infinity,
                    color: Colors.teal.shade50,
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'Today\'s Total Revenue: Rs. ${dailyTotal.toStringAsFixed(2)}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.teal),
                    ),
                  ),
                  Expanded(
                    child: groupedInvoices.isEmpty
                        ? const Center(child: Text('No sales recorded today.'))
                        : ListView.builder(
                            itemCount: groupedInvoices.length,
                            itemBuilder: (ctx, idx) {
                              final inv = groupedInvoices[idx];
                              DateTime dt = inv['date'];
                              String timeStr = DateFormat('hh:mm a').format(dt);
                              List items = inv['items'];

                              return Card(
                                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                elevation: 2,
                                child: Padding(
                                  padding: const EdgeInsets.all(12.0),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Row(
                                            children: [
                                              const Icon(Icons.receipt, color: Colors.teal, size: 20),
                                              const SizedBox(width: 6),
                                              Text(
                                                'Sale at $timeStr',
                                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                              ),
                                            ],
                                          ),
                                          Text(
                                            'Rs. ${(inv['totalAmount'] as double).toStringAsFixed(2)}',
                                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.teal),
                                          ),
                                        ],
                                      ),
                                      const Divider(),
                                      ...items.map<Widget>((item) {
                                        return Padding(
                                          padding: const EdgeInsets.symmetric(vertical: 2.0),
                                          child: Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                '• ${item['quantitySold']}x  ${item['brandName']}',
                                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                                              ),
                                              Text('Rs. ${(item['totalAmount'] as num).toStringAsFixed(2)}'),
                                            ],
                                          ),
                                        );
                                      }).toList(),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),

              Column(
                children: [
                  Container(
                    width: double.infinity,
                    color: Colors.teal.shade50,
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'Monthly Revenue: Rs. ${monthlyTotal.toStringAsFixed(2)}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.teal),
                    ),
                  ),
                  Expanded(
                    child: aggregatedMonthly.isEmpty
                        ? const Center(child: Text('No monthly sales recorded.'))
                        : ListView.builder(
                            itemCount: aggregatedMonthly.length,
                            itemBuilder: (ctx, idx) {
                              final row = aggregatedMonthly[idx];
                              return Card(
                                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                child: ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: Colors.teal,
                                    child: Text(
                                      '${row['totalQty']}x',
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  title: Text(
                                    row['brandName'],
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  subtitle: Text('Sold on ${row['dateStr']}'),
                                  trailing: Text(
                                    'Rs. ${(row['totalAmount'] as double).toStringAsFixed(2)}',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.teal),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
