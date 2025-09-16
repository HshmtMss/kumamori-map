import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:csv/csv.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'dart:convert';
import 'dart:math' as math;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'くまもりマップ',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.brown),
        useMaterial3: true,
        fontFamily: 'NotoSansJP', // 日本語フォントを明示的に指定
      ),
      // 日本語ロケール設定
      locale: const Locale('ja', 'JP'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('ja', 'JP'), // 日本語
      ],
      home: const BearMapPage(),
    );
  }
}

class BearMapPage extends StatefulWidget {
  const BearMapPage({super.key});

  @override
  State<BearMapPage> createState() => _BearMapPageState();
}

class _BearMapPageState extends State<BearMapPage> {
  List<MeshData> meshDataList = [];
  bool isLoading = true;
  final MapController mapController = MapController();
  Position? currentPosition;
  
  // 検索機能用
  final TextEditingController searchController = TextEditingController();
  bool isSearching = false;
  List<SearchResult> searchResults = [];
  
  // ピン機能用（単一ピン）
  CustomPin? selectedPin;
  
  // ヒートマップの透明度（0.0-1.0）
  double heatmapOpacity = 0.4;

  // 透明度調整パネルの表示状態
  bool isOpacityPanelOpen = false;
  
  // 表示する情報のタイプ
  InfoType? activeInfoType;
  
  // 現在地の情報を保持
  MeshData? currentLocationMeshData;
  
  // 地名情報を保持
  String? currentLocationAddress;
  String? selectedPinAddress;
  bool isLoadingAddress = false;
  
  // 地図タイルの種類
  int selectedTileProvider = 0;
  final List<MapTileProvider> tileProviders = [
    MapTileProvider(
      name: '標準地図',
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      attribution: '© OpenStreetMap contributors',
    ),
    MapTileProvider(
      name: '衛星写真',
      urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      attribution: '© Esri',
    ),
    MapTileProvider(
      name: '地形図',
      urlTemplate: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
      subdomains: ['a', 'b', 'c'],
      attribution: '© OpenTopoMap',
    ),
  ];
  
  // ボトムシート用のコントローラー
  final DraggableScrollableController _draggableController = DraggableScrollableController();
  
  // 更新日時（デプロイ時に手動で更新）
  final String lastUpdated = '2025.9.9';
  
  @override
  void initState() {
    super.initState();
    loadCsvData();
    _getCurrentLocation();
  }

  @override
  void dispose() {
    searchController.dispose();
    _draggableController.dispose();
    super.dispose();
  }

  // 逆ジオコーディング（緯度経度から住所を取得）
  Future<String?> reverseGeocode(double lat, double lon) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?'
        'lat=$lat&lon=$lon&format=json&'
        'accept-language=ja-JP,ja;q=0.9&'
        'zoom=18&addressdetails=1'
      );
      
      final response = await http.get(
        uri,
        headers: {
          'User-Agent': 'BearWatchApp/1.0',
          'Accept-Language': 'ja-JP,ja;q=0.9',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        print('API Response language detection:');
        print('Display name: ${data['display_name']}');
        print('Address details: ${data['address']}');
        
        // addressdetailsを使用してより詳細な住所情報を取得
        final address = data['address'] as Map<String, dynamic>?;
        if (address != null) {
          final List<String> addressParts = [];
          
          // 日本の住所階層に従って組み立て
          if (address['province'] != null) {
            addressParts.add(address['province']);
          } else if (address['state'] != null) {
            addressParts.add(address['state']);
          }
          
          if (address['city'] != null) {
            addressParts.add(address['city']);
          } else if (address['town'] != null) {
            addressParts.add(address['town']);
          } else if (address['village'] != null) {
            addressParts.add(address['village']);
          }
          
          if (address['city_district'] != null) {
            addressParts.add(address['city_district']);
          } else if (address['suburb'] != null && address['suburb'].toString().contains('区')) {
            addressParts.add(address['suburb']);
          }
          
          if (address['suburb'] != null && !address['suburb'].toString().contains('区')) {
            addressParts.add(address['suburb']);
          }
          
          if (address['neighbourhood'] != null) {
            addressParts.add(address['neighbourhood']);
          }
          
          if (addressParts.isNotEmpty) {
            return addressParts.join('');
          }
        }
        
        // フォールバック：display_nameを使用
        final displayName = data['display_name'] ?? '';
        if (displayName.isNotEmpty) {
          final parts = displayName.split(',');
          final List<String> japaneseParts = [];
          
          for (int i = 0; i < parts.length && i < 5; i++) {
            final part = parts[i].trim();
            if (!RegExp(r'^\d{3}-\d{4}$').hasMatch(part) && 
                part != '日本' && 
                part != 'Japan' &&
                part.isNotEmpty) {
              japaneseParts.add(part);
            }
          }
          
          if (japaneseParts.isNotEmpty) {
            return japaneseParts.join(' ');
          }
        }
      }
    } catch (e) {
      print('Reverse geocoding error: $e');
    }
    return null;
  }
  
  // 地名検索機能
  Future<void> searchLocation(String query) async {
    if (query.isEmpty) {
      setState(() {
        searchResults = [];
      });
      return;
    }

    setState(() {
      isSearching = true;
    });

    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search?'
        'q=$query&format=json&limit=5&countrycodes=jp&accept-language=ja'
      );
      
      final response = await http.get(
        uri,
        headers: {'User-Agent': 'BearWatchApp/1.0'},
      );

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        setState(() {
          searchResults = data.map((item) => SearchResult(
            displayName: item['display_name'] ?? '',
            lat: double.parse(item['lat']),
            lon: double.parse(item['lon']),
          )).toList();
          isSearching = false;
        });
      } else {
        setState(() {
          isSearching = false;
          searchResults = [];
        });
      }
    } catch (e) {
      print('Search error: $e');
      setState(() {
        isSearching = false;
        searchResults = [];
      });
    }
  }

  // ピンを設定（既存のピンは自動的に削除される）
  void setPin(LatLng position) async {
    MeshData? meshData = getMeshDataAtPosition(position);
    
    setState(() {
      selectedPin = CustomPin(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        position: position,
        color: Colors.red,
        label: '選択地点',
        meshData: meshData,
      );
      activeInfoType = InfoType.pin;
      selectedPinAddress = null;
      isLoadingAddress = true;
    });
    
    // 非同期で住所を取得
    final address = await reverseGeocode(position.latitude, position.longitude);
    if (mounted && selectedPin != null && selectedPin!.position == position) {
      setState(() {
        selectedPinAddress = address;
        isLoadingAddress = false;
      });
    }
  }
  
  // 指定位置のメッシュデータを取得
  MeshData? getMeshDataAtPosition(LatLng position) {
    for (var data in meshDataList) {
      final center = data.latLng;
      final halfLat = 2.5 / 60.0 / 2.0;
      final halfLng = 3.75 / 60.0 / 2.0;
      
      if (position.latitude >= center.latitude - halfLat &&
          position.latitude <= center.latitude + halfLat &&
          position.longitude >= center.longitude - halfLng &&
          position.longitude <= center.longitude + halfLng) {
        return data;
      }
    }
    return null;
  }
  
  // 現在地ボタンが押されたときの処理
  void showCurrentLocationInfo() async {
    if (currentPosition != null) {
      final position = LatLng(currentPosition!.latitude, currentPosition!.longitude);
      currentLocationMeshData = getMeshDataAtPosition(position);
      
      setState(() {
        activeInfoType = InfoType.currentLocation;
        selectedPin = null;
        currentLocationAddress = null;
        isLoadingAddress = true;
      });
      
      mapController.move(position, 15.0);
      
      // 非同期で住所を取得
      final address = await reverseGeocode(position.latitude, position.longitude);
      if (mounted && activeInfoType == InfoType.currentLocation) {
        setState(() {
          currentLocationAddress = address;
          isLoadingAddress = false;
        });
      }
    }
  }

  // 現在地を取得
  Future<void> _getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        print('Location services are disabled.');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          print('Location permissions are denied');
          return;
        }
      }
      
      if (permission == LocationPermission.deniedForever) {
        print('Location permissions are permanently denied');
        return;
      }

      currentPosition = await Geolocator.getCurrentPosition();
      if (mounted) {
        setState(() {});
        
        // 現在地の情報を自動的に表示
        if (currentPosition != null && !isLoading) {
          showCurrentLocationInfo();
        }
      }
    } catch (e) {
      print('Error getting location: $e');
    }
  }

  Future<void> loadCsvData() async {
    try {
      final String csvString = await rootBundle.loadString('assets/bear_combined.csv');
      
      final lines = csvString.split('\n').where((line) => line.trim().isNotEmpty).toList();
      
      List<MeshData> tempList = [];
      Map<String, MeshData> meshMap = {};
      int validMeshCount = 0;
      int invalidMeshCount = 0;
      
      // ヘッダー行の判定
      int startIndex = 0;
      if (lines.isNotEmpty) {
        final firstLine = lines[0].trim();
        if (firstLine.toLowerCase().contains('mesh') || !RegExp(r'^\d').hasMatch(firstLine)) {
          startIndex = 1;
        }
      }
      
      // データ行を処理（第1パス：基本スコア計算）
      for (int i = startIndex; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;
        
        final values = line.split(',').map((e) => e.trim()).toList();
        
        if (values.length >= 5) {
          final meshCode = values[0];
          final second = int.tryParse(values[1]) ?? 0;
          final sixth = int.tryParse(values[2]) ?? 0;
          final latest = int.tryParse(values[3]) ?? 0;
          final latestSingle = int.tryParse(values[4]) ?? 0;
          
          double score = calculateScore(second, sixth, latest, latestSingle);
          
          // スコアが0より大きいメッシュのみを処理（パフォーマンス改善）
          if (score > 0) {
            final latLng = meshCodeToLatLng(meshCode);
            if (latLng != null) {
              final meshData = MeshData(
                meshCode: meshCode,
                latLng: latLng,
                score: score,
                originalScore: score,
                second: second,
                sixth: sixth,
                latest: latest,
                latestSingle: latestSingle,
              );
              tempList.add(meshData);
              meshMap[meshCode] = meshData;
            }
          }
        }
      }
      
      // 第2パス：周囲メッシュを考慮したスコア調整
      for (var meshData in tempList) {
        final neighbors = getNeighborMeshCodes(meshData.meshCode);
        double neighborSum = 0;
        int neighborCount = 0;
        
        for (var neighborCode in neighbors) {
          if (meshMap.containsKey(neighborCode)) {
            neighborSum += meshMap[neighborCode]!.originalScore;
            neighborCount++;
          }
        }
        
        if (neighborCount > 0) {
          double neighborAverage = neighborSum / neighborCount;
          meshData.score = meshData.originalScore * 0.6 + neighborAverage * 0.4;
          
          if (neighborCount >= 6 && neighborAverage > 3.0 && meshData.originalScore <= 0.5) {
            meshData.score = math.max(meshData.score, 1.6);
          }
        }
      }
      
      setState(() {
        meshDataList = tempList;
        isLoading = false;
      });
      
      // CSVデータの読み込みが完了後、現在地情報を表示
      if (currentPosition != null) {
        showCurrentLocationInfo();
      }
    } catch (e) {
      print('Error loading CSV: $e');
      setState(() {
        isLoading = false;
      });
    }
  }

  // 隣接する8つのメッシュコードを取得
  List<String> getNeighborMeshCodes(String meshCode) {
    if (meshCode.length < 8) return [];
    
    List<String> neighbors = [];
    
    final firstMesh = meshCode.substring(0, 4);
    final secondLat = int.parse(meshCode.substring(4, 5));
    final secondLng = int.parse(meshCode.substring(5, 6));
    final thirdCode = int.parse(meshCode.substring(6, 8));
    final thirdLat = thirdCode ~/ 10;
    final thirdLng = thirdCode % 10;
    
    for (int dLat = -1; dLat <= 1; dLat++) {
      for (int dLng = -1; dLng <= 1; dLng++) {
        if (dLat == 0 && dLng == 0) continue;
        
        int newThirdLat = thirdLat + dLat;
        int newThirdLng = thirdLng + dLng;
        int newSecondLat = secondLat;
        int newSecondLng = secondLng;
        
        if (newThirdLat < 0) {
          newThirdLat = 1;
          newSecondLat--;
        } else if (newThirdLat > 1) {
          newThirdLat = 0;
          newSecondLat++;
        }
        
        if (newThirdLng < 0) {
          newThirdLng = 1;
          newSecondLng--;
        } else if (newThirdLng > 1) {
          newThirdLng = 0;
          newSecondLng++;
        }
        
        if (newSecondLat >= 0 && newSecondLat <= 7 && 
            newSecondLng >= 0 && newSecondLng <= 7) {
          String neighborCode = firstMesh + 
              newSecondLat.toString() + 
              newSecondLng.toString() + 
              (newThirdLat * 10 + newThirdLng).toString().padLeft(2, '0');
          neighbors.add(neighborCode);
        }
      }
    }
    
    return neighbors;
  }

  // 実績スコアの計算
  double calculateScore(int second, int sixth, int latest, int latestSingle) {
    double score = latest * 3.0 + sixth * 1.5 + second * 0.5;
    
    if (latestSingle > 0 && score > 0.5) {
      score -= 0.5;
    }
    
    return score;
  }

  // 5kmメッシュコードから緯度経度を計算
  LatLng? meshCodeToLatLng(String meshCode) {
    try {
      if (meshCode.length < 8) return null;
      
      final firstMesh = meshCode.substring(0, 4);
      final latIndex = int.parse(firstMesh.substring(0, 2));
      final lngIndex = int.parse(firstMesh.substring(2, 4));
      
      final secondLat = int.parse(meshCode.substring(4, 5));
      final secondLng = int.parse(meshCode.substring(5, 6));
      
      final thirdCode = int.parse(meshCode.substring(6, 8));
      final thirdLat = (thirdCode ~/ 10);
      final thirdLng = (thirdCode % 10);
      
      double lat = latIndex * 2.0 / 3.0;
      lat += secondLat * 5.0 / 60.0;
      lat += thirdLat * 2.5 / 60.0;
      lat += 1.25 / 60.0;
      
      double lng = lngIndex + 100.0;
      lng += secondLng * 7.5 / 60.0;
      lng += thirdLng * 3.75 / 60.0;
      lng += 1.875 / 60.0;
      
      return LatLng(lat, lng);
    } catch (e) {
      print('Error parsing mesh code $meshCode: $e');
      return null;
    }
  }

  // スコアに応じた色を取得（修正版）
  Color getColorForScore(double score) {
    // スコア0の場合は完全に透明
    if (score == 0) {
      return Colors.transparent;
    }
    
    // 0より大き2未満: 緑
    if (score > 0 && score < 2.0) {
      return Colors.green.withOpacity(heatmapOpacity);
    } 
    // 2以上4未満: 黄色
    else if (score >= 2.0 && score < 4.0) {
      return Colors.yellow.withOpacity(heatmapOpacity);
    } 
    // 4以上5未満: オレンジ
    else if (score >= 4.0 && score < 5.0) {
      return Colors.orange.withOpacity(heatmapOpacity);
    } 
    // 5以上: 赤
    else {
      return Colors.red.withOpacity(heatmapOpacity);
    }
  }

  // スコアからレベル文字列を取得（修正版）
  String getLevelText(double score) {
    if (score == 0) return '安全';
    if (score > 0 && score < 2.0) return '低い';
    if (score >= 2.0 && score < 4.0) return '中程度';
    if (score >= 4.0 && score < 5.0) return 'やや高い';
    if (score >= 5.0) return '高い';
    return '安全';
  }

  // 地図タイプに応じたアイコンを返す
  IconData _getIconForTileProvider(int index) {
    switch (index) {
      case 0:
        return Icons.map;
      case 1:
        return Icons.satellite;
      case 2:
        return Icons.terrain;
      default:
        return Icons.map;
    }
  }

  // ご利用にあたってダイアログを表示
  void _showUsageDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.info_outline, color: Colors.brown.shade700),
              const SizedBox(width: 8),
              Text('ご利用にあたって'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'データについて',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.brown.shade800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '本マップは環境省の公開データ等を基に作成しています。5kmメッシュ単位でのクマ出没危険度を可視化し、地域の参考情報としてご活用いただけます。',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade700,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'ご注意事項',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.brown.shade800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '• 実際の状況は日々変化する可能性があります\n'
                  '• 本アプリの情報は参考情報として利用してください\n'
                  '• 最新の情報は各自治体や関係機関にご確認ください\n'
                  '• 野生動物との遭遇には十分ご注意ください',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade700,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'お問い合わせ',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.brown.shade800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'リサーチコーディネート株式会社',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey.shade700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '東京都新宿区西新宿1-20-3 西新宿高木ビル8F',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () async {
                    final Uri url = Uri.parse('https://www.research-coordinate.co.jp');
                    if (await canLaunchUrl(url)) {
                      await launchUrl(url, mode: LaunchMode.externalApplication);
                    }
                  },
                  child: Text(
                    'https://www.research-coordinate.co.jp',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.blue.shade600,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: () async {
                    final Uri emailUri = Uri(
                      scheme: 'mailto',
                      path: 'contact@research-coordinate.co.jp',
                      query: 'subject=くまもりマップについて',
                    );
                    if (await canLaunchUrl(emailUri)) {
                      await launchUrl(emailUri);
                    }
                  },
                  child: Text(
                    'contact@research-coordinate.co.jp',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.blue.shade600,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('閉じる'),
            ),
          ],
        );
      },
    );
  }

  // 自治体向けダイアログを表示
  void _showMunicipalDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.business, color: Colors.blue.shade700),
              const SizedBox(width: 8),
              Text('自治体の皆様へ'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'より詳細な地域データで住民・観光客の安全を',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue.shade800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '現在のマップは環境省の全国データを使用していますが、自治体様との連携により、より詳細で正確な地域情報の提供が可能です。',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade700,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '連携メリット',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue.shade800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '• リアルタイムでの出没情報更新\n'
                  '• より細かい地域単位での危険度表示\n'
                  '• 住民・観光客への効果的な注意喚起\n'
                  '• 地域に特化したカスタマイズ対応',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade700,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'お問い合わせ',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue.shade800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'リサーチコーディネート株式会社',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey.shade700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '東京都新宿区西新宿1-20-3 西新宿高木ビル8F',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () async {
                    final Uri url = Uri.parse('https://www.research-coordinate.co.jp');
                    if (await canLaunchUrl(url)) {
                      await launchUrl(url, mode: LaunchMode.externalApplication);
                    }
                  },
                  child: Text(
                    'https://www.research-coordinate.co.jp',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.blue.shade600,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: () async {
                    final Uri emailUri = Uri(
                      scheme: 'mailto',
                      path: 'contact@research-coordinate.co.jp',
                      query: 'subject=自治体連携について',
                    );
                    if (await canLaunchUrl(emailUri)) {
                      await launchUrl(emailUri);
                    }
                  },
                  child: Text(
                    'contact@research-coordinate.co.jp',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.blue.shade600,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('閉じる'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                // 地図
                FlutterMap(
                  mapController: mapController,
                  options: MapOptions(
                    initialCenter: const LatLng(36.5, 138.0),
                    initialZoom: 6.0,
                    minZoom: 5.0,
                    maxZoom: 18.0,
                    interactionOptions: const InteractionOptions(
                      enableMultiFingerGestureRace: false,
                      rotationThreshold: 20.0,  // より高い値に設定
                      rotationWinGestures: MultiFingerGesture.none,  // 回転ジェスチャーを完全に無効化
                      pinchZoomThreshold: 0.5,
                      pinchMoveThreshold: 40.0,
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate,  // 回転フラグを除外
                    ),
                    onTap: (tapPosition, point) {
                      setPin(point);
                    },
                    // カメラ移動時にポリゴンを再描画
                    onPositionChanged: (position, hasGesture) {
                      // ズームやパンが変更された時に再描画をトリガー
                      if (hasGesture) {
                        setState(() {
                          // 状態を更新して再描画
                        });
                      }
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: tileProviders[selectedTileProvider].urlTemplate,
                      subdomains: tileProviders[selectedTileProvider].subdomains ?? const [],
                      userAgentPackageName: 'com.example.bear_watch',
                    ),
                    // メッシュデータを表示（パフォーマンス最適化版）
                    PolygonLayer(
                      polygons: meshDataList
                          .where((data) {
                            // スコアが0のメッシュは描画しない
                            return data.score > 0;
                          })
                          .map((data) {
                            final center = data.latLng;
                            final halfLat = 2.5 / 60.0 / 2.0;
                            final halfLng = 3.75 / 60.0 / 2.0;
                            
                            return Polygon(
                              points: [
                                LatLng(center.latitude - halfLat, center.longitude - halfLng),
                                LatLng(center.latitude - halfLat, center.longitude + halfLng),
                                LatLng(center.latitude + halfLat, center.longitude + halfLng),
                                LatLng(center.latitude + halfLat, center.longitude - halfLng),
                              ],
                              color: getColorForScore(data.score),
                              borderColor: Colors.black.withOpacity(0.2),
                              borderStrokeWidth: 0.3,
                            );
                          })
                          .toList(),
                    ),
                    // 選択されたピンレイヤー
                    if (selectedPin != null && (activeInfoType == InfoType.pin || activeInfoType == InfoType.search))
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: selectedPin!.position,
                            width: 40,
                            height: 40,
                            child: Icon(
                              Icons.location_pin,
                              size: 40,
                              color: activeInfoType == InfoType.search ? Colors.blue : Colors.red,
                            ),
                          ),
                        ],
                      ),
                    // 現在地マーカー
                    if (currentPosition != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: LatLng(currentPosition!.latitude, currentPosition!.longitude),
                            width: 40,
                            height: 40,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Container(
                                  decoration: BoxDecoration(
                                    color: Colors.blue.withOpacity(0.2),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                Container(
                                  width: 20,
                                  height: 20,
                                  decoration: BoxDecoration(
                                    color: Colors.blue,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 2),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                
                // 検索バー
                Positioned(
                  left: 16,
                  right: 16,
                  top: MediaQuery.of(context).padding.top + 8,
                  child: Column(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(25),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.15),
                              blurRadius: 10,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            const SizedBox(width: 16),
                            const Icon(Icons.search, color: Colors.grey, size: 26),
                            Expanded(
                              child: TextField(
                                controller: searchController,
                                style: const TextStyle(fontSize: 16),
                                decoration: const InputDecoration(
                                  hintText: 'クマ出没危険度を検索',
                                  hintStyle: TextStyle(fontSize: 15),
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 16),
                                ),
                                onSubmitted: searchLocation,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                border: Border.all(color: Colors.brown.shade600, width: 1.5),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                '🐻 くまもりマップ',
                                style: TextStyle(
                                  color: Colors.brown.shade700,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      
                      // 検索結果
                      if (searchResults.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(top: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Column(
                            children: searchResults.map((result) {
                              return ListTile(
                                title: Text(
                                  result.displayName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 15),
                                ),
                                onTap: () {
                                  mapController.move(
                                    LatLng(result.lat, result.lon),
                                    13.0,
                                  );
                                  
                                  final searchPosition = LatLng(result.lat, result.lon);
                                  final meshData = getMeshDataAtPosition(searchPosition);
                                  
                                  setState(() {
                                    searchResults = [];
                                    searchController.clear();
                                    selectedPin = CustomPin(
                                      id: DateTime.now().millisecondsSinceEpoch.toString(),
                                      position: searchPosition,
                                      color: Colors.blue,
                                      label: result.displayName.split(',')[0],
                                      meshData: meshData,
                                    );
                                    activeInfoType = InfoType.search;
                                    selectedPinAddress = result.displayName.split(',').take(3).join(' ').trim();
                                  });
                                },
                              );
                            }).toList(),
                          ),
                        ),
                    ],
                  ),
                ),
                
                // 地図切り替えボタン
                Positioned(
                  left: 16,
                  top: MediaQuery.of(context).padding.top + 80,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(22),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: PopupMenuButton<int>(
                      initialValue: selectedTileProvider,
                      onSelected: (int value) {
                        setState(() {
                          selectedTileProvider = value;
                        });
                      },
                      itemBuilder: (context) => tileProviders
                          .asMap()
                          .entries
                          .map((entry) => PopupMenuItem<int>(
                                value: entry.key,
                                child: Row(
                                  children: [
                                    Icon(
                                      _getIconForTileProvider(entry.key),
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(entry.value.name),
                                  ],
                                ),
                              ))
                          .toList(),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        child: Icon(_getIconForTileProvider(selectedTileProvider), size: 24),
                      ),
                    ),
                  ),
                ),
                
                // 透明度調整ボタン（地図切り替えボタンの下）
                Positioned(
                  left: 16,
                  top: MediaQuery.of(context).padding.top + 140,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ボタン本体
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            isOpacityPanelOpen = !isOpacityPanelOpen;
                          });
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(22),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          padding: const EdgeInsets.all(10),
                          child: Icon(
                            Icons.opacity,
                            size: 24,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      
                      // 透明度調整パネル（開いているときのみ表示）
                      if (isOpacityPanelOpen)
                        Container(
                          margin: const EdgeInsets.only(top: 8),
                          width: 200,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    '透明度',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  Text(
                                    '${(heatmapOpacity * 100).round()}%',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Colors.grey.shade600,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  activeTrackColor: Colors.brown.shade400,
                                  inactiveTrackColor: Colors.grey.shade300,
                                  thumbColor: Colors.brown.shade600,
                                  overlayColor: Colors.brown.withOpacity(0.2),
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 8,
                                  ),
                                  trackHeight: 4,
                                ),
                                child: Slider(
                                  value: heatmapOpacity,
                                  min: 0.1,
                                  max: 0.9,
                                  divisions: 8,
                                  onChanged: (value) {
                                    setState(() {
                                      heatmapOpacity = value;
                                    });
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                
                // ズームコントロールボタン
                Positioned(
                  right: 16,
                  bottom: 280,
                  child: Column(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(12),
                            topRight: Radius.circular(12),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: IconButton(
                          icon: const Icon(Icons.add, size: 24),
                          onPressed: () {
                            final currentZoom = mapController.camera.zoom;
                            if (currentZoom < 18.0) {
                              mapController.move(
                                mapController.camera.center,
                                (currentZoom + 1).clamp(5.0, 18.0),
                              );
                            }
                          },
                        ),
                      ),
                      Container(
                        width: 48,
                        height: 1,
                        color: Colors.grey.shade300,
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: const BorderRadius.only(
                            bottomLeft: Radius.circular(12),
                            bottomRight: Radius.circular(12),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: IconButton(
                          icon: const Icon(Icons.remove, size: 24),
                          onPressed: () {
                            final currentZoom = mapController.camera.zoom;
                            if (currentZoom > 5.0) {
                              mapController.move(
                                mapController.camera.center,
                                (currentZoom - 1).clamp(5.0, 18.0),
                              );
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                
                // 現在地ボタン
                Positioned(
                  right: 16,
                  top: MediaQuery.of(context).padding.top + 80,
                  child: Container(
                    decoration: BoxDecoration(
                      color: activeInfoType == InfoType.currentLocation ? Colors.blue : Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: IconButton(
                      icon: Icon(
                        Icons.my_location,
                        color: activeInfoType == InfoType.currentLocation ? Colors.white : Colors.black87,
                      ),
                      onPressed: () async {
                        if (currentPosition != null) {
                          showCurrentLocationInfo();
                        } else {
                          await _getCurrentLocation();
                          if (currentPosition != null) {
                            showCurrentLocationInfo();
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('現在地を取得できませんでした')),
                            );
                          }
                        }
                      },
                    ),
                  ),
                ),
                
                // コピーライト
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.8),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${tileProviders[selectedTileProvider].attribution} | データ: 環境省',
                      style: const TextStyle(fontSize: 10, color: Colors.black54),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                
                // ボトムシート
                DraggableScrollableSheet(
                  controller: _draggableController,
                  initialChildSize: 0.30,
                  minChildSize: 0.30,
                  maxChildSize: 0.7,
                  builder: (context, scrollController) {
                    return Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(25),
                          topRight: Radius.circular(25),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.15),
                            blurRadius: 20,
                            offset: const Offset(0, -4),
                          ),
                        ],
                      ),
                      child: SingleChildScrollView(
                        controller: scrollController,
                        child: Column(
                          children: [
                            // ハンドル
                            Container(
                              margin: const EdgeInsets.symmetric(vertical: 12),
                              width: 40,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.grey[300],
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            
                            // コンテンツ
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // 場所情報ヘッダー
                                  if (activeInfoType != null)
                                    Row(
                                      children: [
                                        Container(
                                          width: 40,
                                          height: 40,
                                          decoration: BoxDecoration(
                                            color: Colors.orange.shade50,
                                            borderRadius: BorderRadius.circular(20),
                                          ),
                                          child: Icon(
                                            activeInfoType == InfoType.currentLocation 
                                                ? Icons.my_location 
                                                : Icons.location_pin,
                                            color: activeInfoType == InfoType.currentLocation 
                                                ? Colors.blue 
                                                : Colors.red,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                activeInfoType == InfoType.currentLocation 
                                                    ? '現在地' 
                                                    : 'ピン位置',
                                                style: const TextStyle(
                                                  fontSize: 18,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              if (!isLoadingAddress && _getDisplayAddress() != null)
                                                Text(
                                                  _getDisplayAddress()!,
                                                  style: const TextStyle(
                                                    fontSize: 14,
                                                    color: Colors.grey,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  
                                  const SizedBox(height: 12),
                                  
                                  // 危険度インジケーター
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(color: Colors.grey.shade200),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'クマ出没危険度',
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.black87,
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        
                                        // 5段階評価バー
                                        LayoutBuilder(
                                          builder: (context, constraints) {
                                            final barWidth = constraints.maxWidth;
                                            final segmentWidth = barWidth / 5;
                                            
                                            // スコアに基づくインジケーター位置を計算
                                            double indicatorPosition = 0;
                                            int activeSegment = 0;
                                            
                                            if (_getDisplayMeshData() != null) {
                                              final score = _getDisplayMeshData()!.score;
                                              if (score == 0) {
                                                activeSegment = 0;
                                                indicatorPosition = segmentWidth * 0.5;
                                              } else if (score > 0 && score < 2.0) {
                                                activeSegment = 1;
                                                indicatorPosition = segmentWidth * 1.5;
                                              } else if (score >= 2.0 && score < 4.0) {
                                                activeSegment = 2;
                                                indicatorPosition = segmentWidth * 2.5;
                                              } else if (score >= 4.0 && score < 5.0) {
                                                activeSegment = 3;
                                                indicatorPosition = segmentWidth * 3.5;
                                              } else {
                                                activeSegment = 4;
                                                indicatorPosition = segmentWidth * 4.5;
                                              }
                                            }
                                            
                                            return Column(
                                              children: [
                                                // 5段階のセグメントバー
                                                Row(
                                                  children: List.generate(5, (index) {
                                                    Color segmentColor;
                                                    bool isActive = index == activeSegment;
                                                    
                                                    switch (index) {
                                                      case 0:
                                                        segmentColor = Colors.cyan;
                                                        break;
                                                      case 1:
                                                        segmentColor = Colors.green;
                                                        break;
                                                      case 2:
                                                        segmentColor = Colors.yellow.shade700;
                                                        break;
                                                      case 3:
                                                        segmentColor = Colors.orange;
                                                        break;
                                                      case 4:
                                                        segmentColor = Colors.red;
                                                        break;
                                                      default:
                                                        segmentColor = Colors.grey;
                                                    }
                                                    
                                                    return Expanded(
                                                      child: Container(
                                                        height: 24,
                                                        margin: EdgeInsets.only(
                                                          left: index == 0 ? 0 : 1,
                                                        ),
                                                        decoration: BoxDecoration(
                                                          color: isActive 
                                                              ? segmentColor 
                                                              : segmentColor.withOpacity(0.2),
                                                          borderRadius: BorderRadius.only(
                                                            topLeft: index == 0 
                                                                ? const Radius.circular(12) 
                                                                : Radius.zero,
                                                            bottomLeft: index == 0 
                                                                ? const Radius.circular(12) 
                                                                : Radius.zero,
                                                            topRight: index == 4 
                                                                ? const Radius.circular(12) 
                                                                : Radius.zero,
                                                            bottomRight: index == 4 
                                                                ? const Radius.circular(12) 
                                                                : Radius.zero,
                                                          ),
                                                          border: Border.all(
                                                            color: isActive 
                                                                ? segmentColor.withOpacity(0.8)
                                                                : Colors.grey.shade300,
                                                            width: isActive ? 2 : 1,
                                                          ),
                                                        ),
                                                      ),
                                                    );
                                                  }),
                                                ),
                                                const SizedBox(height: 6),
                                                // ラベル
                                                Row(
                                                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                                                  children: const [
                                                    Text('安全', style: TextStyle(fontSize: 11, color: Colors.grey)),
                                                    Text('低い', style: TextStyle(fontSize: 11, color: Colors.grey)),
                                                    Text('中程度', style: TextStyle(fontSize: 11, color: Colors.grey)),
                                                    Text('やや高い', style: TextStyle(fontSize: 11, color: Colors.grey)),
                                                    Text('高い', style: TextStyle(fontSize: 11, color: Colors.grey)),
                                                  ],
                                                ),
                                              ],
                                            );
                                          },
                                        ),
                                        const SizedBox(height: 10),
                                        
                                        // 危険度レベル表示（修正版）
                                        if (_getDisplayMeshData() != null) ...[
                                          Center(
                                            child: Column(
                                              children: [
                                                Text(
                                                  getLevelText(_getDisplayMeshData()!.score),
                                                  style: TextStyle(
                                                    fontSize: 20,
                                                    fontWeight: FontWeight.bold,
                                                    color: _getDisplayMeshData()!.score == 0
                                                        ? Colors.cyan
                                                        : _getDisplayMeshData()!.score < 2.0
                                                            ? Colors.green
                                                            : _getDisplayMeshData()!.score < 4.0
                                                                ? Colors.yellow.shade700
                                                                : _getDisplayMeshData()!.score < 5.0
                                                                    ? Colors.orange
                                                                    : Colors.red,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                // デバッグ用：実際のスコア値を表示
                                                Text(
                                                  'スコア: ${_getDisplayMeshData()!.score.toStringAsFixed(2)}',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.grey,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  _getDisplayMeshData()!.score == 0
                                                      ? 'クマ出没の報告がない地域です'
                                                      : _getDisplayMeshData()!.score < 2.0
                                                          ? 'クマ出没の報告は少ない地域です'
                                                          : _getDisplayMeshData()!.score < 4.0
                                                              ? 'クマ出没の報告がある地域です'
                                                              : _getDisplayMeshData()!.score < 5.0
                                                                  ? '最近、クマ出没の報告がある地域です'
                                                                  : '最近、クマ出没の報告が多い地域です',
                                                  style: const TextStyle(fontSize: 14, color: Colors.grey),
                                                  textAlign: TextAlign.center,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ] else ...[
                                          const Center(
                                            child: Text(
                                              'クマ出没の報告がない地域です',
                                              style: TextStyle(fontSize: 14, color: Colors.grey),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  
                                  const SizedBox(height: 16),
                                  
                                  // 情報へのリンクボタン
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          onPressed: () => _showUsageDialog(context),
                                          icon: Icon(Icons.info_outline, size: 18),
                                          label: Text('ご利用にあたって'),
                                          style: OutlinedButton.styleFrom(
                                            padding: EdgeInsets.symmetric(vertical: 12),
                                            side: BorderSide(color: Colors.brown.shade300),
                                            foregroundColor: Colors.brown.shade700,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          onPressed: () => _showMunicipalDialog(context),
                                          icon: Icon(Icons.business, size: 18),
                                          label: Text('自治体の皆様へ'),
                                          style: OutlinedButton.styleFrom(
                                            padding: EdgeInsets.symmetric(vertical: 12),
                                            side: BorderSide(color: Colors.blue.shade300),
                                            foregroundColor: Colors.blue.shade700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),

                                  // 更新日時
                                  Container(
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.update, size: 12, color: Colors.grey.shade400),
                                        const SizedBox(width: 4),
                                        Text(
                                          '最終更新: $lastUpdated',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.grey.shade400,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),

                                  const SizedBox(height: 20),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
    );
  }

  // 統計カード
  Widget _buildStatCard(String label, String value, Color bgColor, Color textColor) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  // 表示する位置情報を取得
  LatLng _getDisplayPosition() {
    if (activeInfoType == InfoType.currentLocation && currentPosition != null) {
      return LatLng(currentPosition!.latitude, currentPosition!.longitude);
    } else if (selectedPin != null) {
      return selectedPin!.position;
    }
    return const LatLng(0, 0);
  }
  
  // 表示するメッシュデータを取得
  MeshData? _getDisplayMeshData() {
    if (activeInfoType == InfoType.currentLocation) {
      return currentLocationMeshData;
    } else if (selectedPin != null) {
      return selectedPin!.meshData;
    }
    return null;
  }
  
  // 表示する住所情報を取得
  String? _getDisplayAddress() {
    if (activeInfoType == InfoType.currentLocation) {
      return currentLocationAddress;
    } else if (selectedPin != null) {
      return selectedPinAddress;
    }
    return null;
  }
}

// データクラス群
class MeshData {
  final String meshCode;
  final LatLng latLng;
  double score;
  final double originalScore;
  final int second;
  final int sixth;
  final int latest;
  final int latestSingle;

  MeshData({
    required this.meshCode,
    required this.latLng,
    required this.score,
    required this.originalScore,
    required this.second,
    required this.sixth,
    required this.latest,
    required this.latestSingle,
  });
}

class MapTileProvider {
  final String name;
  final String urlTemplate;
  final List<String>? subdomains;
  final String attribution;

  MapTileProvider({
    required this.name,
    required this.urlTemplate,
    this.subdomains,
    required this.attribution,
  });
}

class SearchResult {
  final String displayName;
  final double lat;
  final double lon;

  SearchResult({
    required this.displayName,
    required this.lat,
    required this.lon,
  });
}

enum InfoType {
  currentLocation,
  pin,
  search,
}

class CustomPin {
  final String id;
  final LatLng position;
  final Color color;
  final String label;
  final MeshData? meshData;

  CustomPin({
    required this.id,
    required this.position,
    required this.color,
    required this.label,
    this.meshData,
  });
}

