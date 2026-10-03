import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:intl/intl.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DatabaseHelper.instance.database;
  runApp(const DaryaKhanPharmacyApp());
}

class DaryaKhanPharmacyApp extends StatelessWidget {
  const DaryaKhanPharmacyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Darya Khan Pharmacy',
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
// 1. LOCAL DATABASE HELPER (SQLite)
// ==========================================
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('darya_khan_pharmacy.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 2,
      onCreate: _createDB,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE sales ADD COLUMN unitPrice REAL DEFAULT 0.0');
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
        medicineId INTEGER NOT NULL,
        brandName TEXT NOT NULL,
        quantitySold INTEGER NOT NULL,
        unitPrice REAL NOT NULL,
        totalAmount REAL NOT NULL,
        saleDate TEXT NOT NULL
      )
    ''');
  }

  // --- Inventory Operations ---
  Future<int> addMedicine(Map<String, dynamic> row) async {
    final db = await instance.database;
    return await db.insert('inventory', row);
  }

  Future<List<Map<String, dynamic>>> getAllMedicines() async {
    final db = await instance.database;
    return await db.query('inventory', orderBy: 'brandName ASC');
  }

  Future<int> updateMedicine(int id, Map<String, dynamic> row) async {
    final db = await instance.database;
    return await db.update('inventory', row, where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteMedicine(int id) async {
    final db = await instance.database;
    return await db.delete('inventory', where: 'id = ?', whereArgs: [id]);
  }

  // --- POS & Sales Operations ---
  Future<bool> processSale(int medicineId, String brandName, int qty, double unitPrice, double total) async {
    final db = await instance.database;
    final List<Map<String, dynamic>> res = await db.query('inventory', where: 'id = ?', whereArgs: [medicineId]);
    if (res.isEmpty) return false;

    int currentQty = res.first['quantity'] as int;
    if (currentQty < qty) return false;

    await db.update('inventory', {'quantity': currentQty - qty}, where: 'id = ?', whereArgs: [medicineId]);

    await db.insert('sales', {
      'medicineId': medicineId,
      'brandName': brandName,
      'quantitySold': qty,
      'unitPrice': unitPrice,
      'totalAmount': total,
      'saleDate': DateTime.now().toIso8601String(),
    });

    return true;
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
        title: const Text('Darya Khan Pharmacy'),
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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
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
            children: [
              Text(
                item == null ? 'Add New Medicine' : 'Edit Medicine Stock',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.teal),
              ),
              const SizedBox(height: 12),
              TextField(controller: brandCtrl, decoration: const InputDecoration(labelText: 'Brand Name (e.g. Panadol)')),
              TextField(controller: genericCtrl, decoration: const InputDecoration(labelText: 'Generic Name (e.g. Paracetamol)')),
              Row(
                children: [
                  Expanded(child: TextField(controller: unitPriceCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Unit Price (Rs)'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: packPriceCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Pack Price (Rs)'))),
                ],
              ),
              Row(
                children: [
                  Expanded(child: TextField(controller: qtyCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Quantity in Stock'))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: expiryCtrl,
                      readOnly: true,
                      decoration: const InputDecoration(labelText: 'Expiry Date (YYYY-MM-DD)'),
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
              const SizedBox(height: 20),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, minimumSize: const Size.fromHeight(45)),
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

                  Navigator.pop(context);
                  _refreshInventory();
                },
                child: Text(item == null ? 'Save Stock' : 'Update Stock', style: const TextStyle(color: Colors.white)),
              )
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
// 4. POS BILLING TAB (WITH LIVE SEARCH)
// ==========================================
class POSBillingTab extends StatefulWidget {
  const POSBillingTab({super.key});

  @override
  State<POSBillingTab> createState() => _POSBillingTabState();
}

class _POSBillingTabState extends State<POSBillingTab> {
  List<Map<String, dynamic>> _medicines = [];
  Map<String, dynamic>? _selectedMedicine;
  final qtyController = TextEditingController(text: '1');
  double _calculatedTotal = 0.0;

  @override
  void initState() {
    super.initState();
    _loadMedicines();
  }

  void _loadMedicines() async {
    final data = await DatabaseHelper.instance.getAllMedicines();
    setState(() {
      _medicines = data;
    });
  }

  void _calculateTotal() {
    if (_selectedMedicine != null) {
      int qty = int.tryParse(qtyController.text) ?? 1;
      double price = (_selectedMedicine!['unitPrice'] as num).toDouble();
      setState(() {
        _calculatedTotal = price * qty;
      });
    }
  }

  void _openSearchDialog() {
    String searchKeyword = '';
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final filtered = _medicines.where((med) {
              final brand = med['brandName'].toString().toLowerCase();
              final generic = med['genericName'].toString().toLowerCase();
              return brand.contains(searchKeyword.toLowerCase()) || generic.contains(searchKeyword.toLowerCase());
            }).toList();

            return AlertDialog(
              title: const Text('Select Medicine'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'Type brand or generic name...',
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
                                  subtitle: Text('${med['genericName']} | Rs. ${med['unitPrice']}'),
                                  trailing: Text('Stock: ${med['quantity']}'),
                                  onTap: () {
                                    setState(() {
                                      _selectedMedicine = med;
                                      _calculateTotal();
                                    });
                                    Navigator.pop(context);
                                  },
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
                  child: const Text('Cancel'),
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Point of Sale Counter', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.teal)),
          const SizedBox(height: 16),
          
          InkWell(
            onTap: _openSearchDialog,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.teal),
                borderRadius: BorderRadius.circular(8),
                color: Colors.white,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      _selectedMedicine != null
                          ? '${_selectedMedicine!['brandName']} (${_selectedMedicine!['genericName']})'
                          : 'Tap to Search & Select Medicine...',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: _selectedMedicine != null ? FontWeight.bold : FontWeight.normal,
                        color: _selectedMedicine != null ? Colors.black87 : Colors.grey.shade600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(Icons.search, color: Colors.teal),
                ],
              ),
            ),
          ),

          if (_selectedMedicine != null) ...[
            const SizedBox(height: 12),
            Card(
              color: Colors.teal.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Selected: ${_selectedMedicine!['brandName']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text('Unit Price: Rs. ${_selectedMedicine!['unitPrice']}'),
                      ],
                    ),
                    Text('Available Stock: ${_selectedMedicine!['quantity']}', style: const TextStyle(color: Colors.teal, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ],

          const SizedBox(height: 16),
          TextField(
            controller: qtyController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Quantity to Dispense', border: OutlineInputBorder()),
            onChanged: (_) => _calculateTotal(),
          ),
          const SizedBox(height: 20),
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Total Payable:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  Text('Rs. ${_calculatedTotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.teal)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.teal,
              minimumSize: const Size.fromHeight(50),
            ),
            onPressed: () async {
              if (_selectedMedicine == null) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select a medicine first!')));
                return;
              }
              int qty = int.tryParse(qtyController.text) ?? 1;
              double uPrice = (_selectedMedicine!['unitPrice'] as num).toDouble();

              bool success = await DatabaseHelper.instance.processSale(
                _selectedMedicine!['id'],
                _selectedMedicine!['brandName'],
                qty,
                uPrice,
                _calculatedTotal,
              );

              if (success) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Sale completed & stock updated!')),
                );
                setState(() {
                  _selectedMedicine = null;
                  qtyController.text = '1';
                  _calculatedTotal = 0.0;
                });
                _loadMedicines();
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Error: Not enough stock available!'), backgroundColor: Colors.red),
                );
              }
            },
            child: const Text('Complete Sale', style: TextStyle(fontSize: 18, color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// 5. DETAILED SALES REPORTS TAB
// ==========================================
class SalesReportsTab extends StatefulWidget {
  const SalesReportsTab({super.key});

  @override
  State<SalesReportsTab> createState() => _SalesReportsTabState();
}

class _SalesReportsTabState extends State<SalesReportsTab> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<Map<String, dynamic>> _dailySalesList = [];
  List<Map<String, dynamic>> _monthlySalesList = [];
  double _dailyTotal = 0.0;
  double _monthlyTotal = 0.0;

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

    double dTotal = dailyData.fold(0.0, (sum, item) => sum + (item['totalAmount'] as num).toDouble());
    double mTotal = monthlyData.fold(0.0, (sum, item) => sum + (item['totalAmount'] as num).toDouble());

    setState(() {
      _dailySalesList = dailyData;
      _monthlySalesList = monthlyData;
      _dailyTotal = dTotal;
      _monthlyTotal = mTotal;
    });
  }

  Widget _buildSalesListView(List<Map<String, dynamic>> salesList, double grandTotal) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: Colors.teal.shade50,
          padding: const EdgeInsets.all(12),
          child: Text(
            'Total Revenue: Rs. ${grandTotal.toStringAsFixed(2)}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.teal),
          ),
        ),
        Expanded(
          child: salesList.isEmpty
              ? const Center(child: Text('No transaction history found.'))
              : ListView.builder(
                  itemCount: salesList.length,
                  itemBuilder: (ctx, idx) {
                    final item = salesList[idx];
                    DateTime dt = DateTime.parse(item['saleDate']);
                    String formattedTime = DateFormat('hh:mm a - dd MMM').format(dt);

                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.teal,
                          child: Text('${item['quantitySold']}x', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ),
                        title: Text(item['brandName'], style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('Rate: Rs. ${item['unitPrice'] ?? 0} | $formattedTime'),
                        trailing: Text(
                          'Rs. ${(item['totalAmount'] as num).toStringAsFixed(2)}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.teal),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          labelColor: Colors.teal,
          unselectedLabelColor: Colors.grey,
          indicatorColor: Colors.teal,
          tabs: const [
            Tab(icon: Icon(Icons.today), text: 'Today\'s Breakdown'),
            Tab(icon: Icon(Icons.calendar_month), text: 'Monthly History'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildSalesListView(_dailySalesList, _dailyTotal),
              _buildSalesListView(_monthlySalesList, _monthlyTotal),
            ],
          ),
        ),
      ],
    );
  }
}
