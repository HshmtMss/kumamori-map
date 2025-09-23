import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:csv/csv.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'package:share_plus/share_plus.dart';

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
        fontFamily: 'Hiragino Sans',
      ),
      locale: const Locale('ja', 'JP'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('ja', 'JP'),
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
  
  final TextEditingController searchController = TextEditingController();
  bool isSearching = false;
  List<SearchResult> searchResults = [];
  
  CustomPin? selectedPin;
  double heatmapOpacity = 0.4;
  InfoType? activeInfoType;
  MeshData? currentLocationMeshData;
  String? currentLocationAddress;
  String? selectedPinAddress;
  bool isLoadingAddress = false;
  bool isSettingsPanelOpen = false;
  
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
  
  final DraggableScrollableController _draggableController = DraggableScrollableController();
  final String lastUpdated = '2025年9月23日 11:00';
  
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

  // シンプルで確実なシェア機能
  // ハイブリッドシェア機能 - SNS直接シェア + ネイティブシェア
  Future<void> _shareToSNS(String platform) async {
    String shareText = 'くまもりマップでクマ出没危険度をチェック！\n'
      '全国のクマ出没情報を地図で確認できます。\n\n'
      '安全な外出のためにぜひご活用ください。\n'
      '#くまもりマップ #クマ出没 #登山 #ハイキング #キャンプ #アウトドア #トレッキング #紅葉 #山菜取り';

    String appUrl = 'https://kumamori-map.netlify.app/';
    
    Uri? shareUri;
    
    switch (platform) {
      case 'x':
        // Xはウェブ版を使用（最も安定）
        String text = Uri.encodeComponent('$shareText\n$appUrl');
        shareUri = Uri.parse('https://twitter.com/intent/tweet?text=$text');
        break;
        
      case 'facebook':
        // FacebookはURLのみでシェア（シンプルで確実）
        String url = Uri.encodeComponent(appUrl);
        shareUri = Uri.parse('https://www.facebook.com/sharer/sharer.php?u=$url');
        break;
        
      case 'line':
        // LINEはウェブ版を使用
        String text = Uri.encodeComponent(shareText);
        String url = Uri.encodeComponent(appUrl);
        shareUri = Uri.parse('https://social-plugins.line.me/lineit/share?url=$url&text=$text');
        break;
        
      default:
        return;
    }

    try {
      if (await canLaunchUrl(shareUri)) {
        await launchUrl(shareUri, mode: LaunchMode.externalApplication);
      } else {
        // 失敗した場合はネイティブシェアにフォールバック
        await _shareWithNative();
      }
    } catch (e) {
      // エラーの場合もネイティブシェアにフォールバック
      await _shareWithNative();
    }
  }

  // ネイティブシェア機能
  Future<void> _shareWithNative() async {
    String shareText = 'くまもりマップでクマ出没危険度をチェック！\n'
      '全国のクマ出没情報を地図で確認できます。\n\n'
      '安全な外出のためにぜひご活用ください。\n\n'
      'https://kumamori-map.netlify.app/\n\n'
      '#くまもりマップ #クマ出没 #登山 #ハイキング #キャンプ #アウトドア #トレッキング #紅葉 #山菜取り';

    try {
      await Share.share(
        shareText,
        subject: 'くまもりマップ - クマ出没危険度マップ',
      );
    } catch (e) {
      // 最終フォールバック: クリップボードにコピー
      await Clipboard.setData(ClipboardData(text: shareText));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('シェア内容をクリップボードにコピーしました'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // 位置情報付きネイティブシェア
  Future<void> _shareLocationWithNative() async {
    String locationInfo = '';
    if (_getDisplayAddress() != null) {
      locationInfo = '場所: ${_getDisplayAddress()}\n';
    }
    
    String riskInfo = '';
    if (_getDisplayMeshData() != null) {
      riskInfo = 'クマ出没危険度: ${getLevelText(_getDisplayMeshData()!.score)}\n';
    }

    String shareText = 'くまもりマップでクマ出没危険度をチェック！\n\n'
      '$locationInfo'
      '$riskInfo\n'
      '全国のクマ出没情報を地図で確認できます。\n'
      '安全な外出のためにぜひご活用ください。\n\n'
      'https://kumamori-map.netlify.app/\n\n'
      '#くまもりマップ #クマ出没 #登山 #ハイキング #キャンプ #アウトドア';

    try {
      await Share.share(
        shareText,
        subject: 'くまもりマップ - 位置情報付きシェア',
      );
    } catch (e) {
      await Clipboard.setData(ClipboardData(text: shareText));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('シェア内容をクリップボードにコピーしました'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // 改良されたシェアダイアログ
  void _showShareDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.share, color: Colors.brown.shade700),
                    const SizedBox(width: 8),
                    const Text(
                      'シェアする',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    // SNS直接シェア
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildShareOption(
                          icon: FontAwesomeIcons.xTwitter,
                          label: 'X',
                          color: Colors.black,
                          onTap: () {
                            Navigator.pop(context);
                            _shareToSNS('x');
                          },
                        ),
                        _buildShareOption(
                          icon: FontAwesomeIcons.facebookF,
                          label: 'Facebook',
                          color: const Color(0xFF4267B2),
                          onTap: () {
                            Navigator.pop(context);
                            _shareToSNS('facebook');
                          },
                        ),
                        _buildShareOption(
                          icon: FontAwesomeIcons.line,
                          label: 'LINE',
                          color: const Color(0xFF00B900),
                          onTap: () {
                            Navigator.pop(context);
                            _shareToSNS('line');
                          },
                        ),
                      ],
                    ),
                    
                    const SizedBox(height: 20),
                    
                    // その他のシェア方法
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'その他の方法',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade600,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    
                    const SizedBox(height: 8),
                    
                    // ネイティブシェアボタン
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _shareWithNative();
                        },
                        icon: const Icon(Icons.share, size: 20),
                        label: const Text('端末のシェア機能を使う'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.brown.shade600,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    
                    const SizedBox(height: 8),
                    
                    // 位置情報付きシェア
                    if (activeInfoType != null)
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Navigator.pop(context);
                            _shareLocationWithNative();
                          },
                          icon: const Icon(Icons.location_on, size: 20),
                          label: const Text('現在地の危険度も含めてシェア'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue.shade600,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }
  // Future<void> _shareToSNS(String platform) async {
  //   String shareText = 'くまもりマップでクマ出没危険度をチェック！\n'
  //     '全国のクマ出没情報を地図で確認できます。\n\n'
  //     '安全な外出のためにぜひご活用ください。\n'
  //     '#くまもりマップ #クマ出没 #登山 #ハイキング #キャンプ #アウトドア #トレッキング #紅葉 #山菜取り';

  //   String appUrl = 'https://kumamori-map.netlify.app/';
  //   String encodedText = Uri.encodeComponent(shareText);
  //   String encodedUrl = Uri.encodeComponent(appUrl);
    
  //   Uri? shareUri;
    
  //   switch (platform) {
  //     case 'x':
  //       shareUri = Uri.parse('https://twitter.com/intent/tweet?text=$encodedText&url=$encodedUrl');
  //       break;
  //     case 'facebook':
  //       shareUri = Uri.parse('https://www.facebook.com/sharer/sharer.php?u=$encodedUrl&quote=$encodedText');
  //       break;
  //     case 'line':
  //       shareUri = Uri.parse('https://social-plugins.line.me/lineit/share?url=$encodedUrl&text=$encodedText');
  //       break;
  //     case 'instagram':
  //       try {
  //         shareUri = Uri.parse('instagram://');
  //         if (await canLaunchUrl(shareUri)) {
  //           await launchUrl(shareUri, mode: LaunchMode.externalApplication);
  //           await Clipboard.setData(ClipboardData(text: '$shareText\n$appUrl'));
  //           if (mounted) {
  //             ScaffoldMessenger.of(context).showSnackBar(
  //               const SnackBar(
  //                 content: Text('インスタグラムが開きました。シェア内容をクリップボードにコピーしました。'),
  //                 duration: Duration(seconds: 3),
  //               ),
  //             );
  //           }
  //         } else {
  //           shareUri = Uri.parse('https://www.instagram.com/');
  //           await launchUrl(shareUri, mode: LaunchMode.externalApplication);
  //           await Clipboard.setData(ClipboardData(text: '$shareText\n$appUrl'));
  //           if (mounted) {
  //             ScaffoldMessenger.of(context).showSnackBar(
  //               const SnackBar(
  //                 content: Text('インスタグラムのウェブ版が開きました。シェア内容をクリップボードにコピーしました。'),
  //                 duration: Duration(seconds: 3),
  //               ),
  //             );
  //           }
  //         }
  //         return;
  //       } catch (e) {
  //         await Clipboard.setData(ClipboardData(text: '$shareText\n$appUrl'));
  //         if (mounted) {
  //           ScaffoldMessenger.of(context).showSnackBar(
  //             const SnackBar(
  //               content: Text('シェア内容をクリップボードにコピーしました'),
  //               duration: Duration(seconds: 2),
  //             ),
  //           );
  //         }
  //         return;
  //       }
  //     default:
  //       return;
  //   }

  //   try {
  //     if (await canLaunchUrl(shareUri)) {
  //       await launchUrl(shareUri, mode: LaunchMode.externalApplication);
  //     } else {
  //       await Clipboard.setData(ClipboardData(text: '$shareText\n$appUrl'));
  //       if (mounted) {
  //         ScaffoldMessenger.of(context).showSnackBar(
  //           const SnackBar(
  //             content: Text('シェア内容をクリップボードにコピーしました'),
  //             duration: Duration(seconds: 2),
  //           ),
  //         );
  //       }
  //     }
  //   } catch (e) {
  //     await Clipboard.setData(ClipboardData(text: '$shareText\n$appUrl'));
  //     if (mounted) {
  //       ScaffoldMessenger.of(context).showSnackBar(
  //         const SnackBar(
  //           content: Text('シェア内容をクリップボードにコピーしました'),
  //           duration: Duration(seconds: 2),
  //         ),
  //       );
  //     }
  //   }
  // }

  // // SNSシェアダイアログを表示
  // void _showShareDialog(BuildContext context) {
  //   showModalBottomSheet(
  //     context: context,
  //     backgroundColor: Colors.transparent,
  //     builder: (BuildContext context) {
  //       return Container(
  //         decoration: const BoxDecoration(
  //           color: Colors.white,
  //           borderRadius: BorderRadius.only(
  //             topLeft: Radius.circular(20),
  //             topRight: Radius.circular(20),
  //           ),
  //         ),
  //         child: Column(
  //           mainAxisSize: MainAxisSize.min,
  //           children: [
  //             Container(
  //               margin: const EdgeInsets.symmetric(vertical: 12),
  //               width: 40,
  //               height: 4,
  //               decoration: BoxDecoration(
  //                 color: Colors.grey[300],
  //                 borderRadius: BorderRadius.circular(2),
  //               ),
  //             ),
              
  //             Padding(
  //               padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
  //               child: Row(
  //                 children: [
  //                   Icon(Icons.share, color: Colors.brown.shade700),
  //                   const SizedBox(width: 8),
  //                   const Text(
  //                     'シェアする',
  //                     style: TextStyle(
  //                       fontSize: 18,
  //                       fontWeight: FontWeight.bold,
  //                     ),
  //                   ),
  //                 ],
  //               ),
  //             ),
              
  //             Padding(
  //               padding: const EdgeInsets.all(20),
  //               child: Column(
  //                 children: [
  //                   Row(
  //                     mainAxisAlignment: MainAxisAlignment.spaceEvenly,
  //                     children: [
  //                       _buildShareOption(
  //                         icon: FontAwesomeIcons.xTwitter,
  //                         label: 'X',
  //                         color: Colors.black,
  //                         onTap: () {
  //                           Navigator.pop(context);
  //                           _shareToSNS('x');
  //                         },
  //                       ),
  //                       _buildShareOption(
  //                         icon: FontAwesomeIcons.facebookF,
  //                         label: 'Facebook',
  //                         color: const Color(0xFF4267B2),
  //                         onTap: () {
  //                           Navigator.pop(context);
  //                           _shareToSNS('facebook');
  //                         },
  //                       ),
  //                       _buildShareOption(
  //                         icon: FontAwesomeIcons.line,
  //                         label: 'LINE',
  //                         color: const Color(0xFF00B900),
  //                         onTap: () {
  //                           Navigator.pop(context);
  //                           _shareToSNS('line');
  //                         },
  //                       ),
  //                     ],
  //                   ),
                    
  //                   const SizedBox(height: 16),
                    
  //                   Row(
  //                     mainAxisAlignment: MainAxisAlignment.spaceEvenly,
  //                     children: [
  //                       _buildShareOption(
  //                         icon: FontAwesomeIcons.instagram,
  //                         label: 'Instagram',
  //                         color: const Color(0xFFE4405F),
  //                         onTap: () {
  //                           Navigator.pop(context);
  //                           _shareToSNS('instagram');
  //                         },
  //                       ),
  //                       _buildShareOption(
  //                         icon: FontAwesomeIcons.copy,
  //                         label: 'コピー',
  //                         color: Colors.grey.shade600,
  //                         onTap: () async {
  //                           Navigator.pop(context);
                            
  //                           String shareText = '';
  //                           String? locationText = _getDisplayAddress();
  //                           String riskLevel = _getDisplayMeshData() != null 
  //                               ? getLevelText(_getDisplayMeshData()!.score) 
  //                               : '安全';
                            
  //                           shareText = 'くまもりマップでクマ出没危険度をチェック！\n'
  //                           '全国のクマ出没情報を地図で確認できます。\n\n'
  //                           '安全な外出のためにぜひご活用ください。\n'
  //                           'https://kumamori-map.netlify.app/\n\n'
  //                           '#くまもりマップ #クマ出没 #登山 #ハイキング #キャンプ #アウトドア #トレッキング #紅葉 #山菜取り';
                            
  //                           await Clipboard.setData(ClipboardData(text: shareText));
  //                           if (mounted) {
  //                             ScaffoldMessenger.of(context).showSnackBar(
  //                               const SnackBar(
  //                                 content: Text('クリップボードにコピーしました'),
  //                                 duration: Duration(seconds: 2),
  //                               ),
  //                             );
  //                           }
  //                         },
  //                       ),
  //                       const SizedBox(width: 64),
  //                     ],
  //                   ),
  //                 ],
  //               ),
  //             ),
  //             const SizedBox(height: 20),
  //           ],
  //         ),
  //       );
  //     },
  //   );
  // }

  Widget _buildShareOption({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

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
        final address = data['address'] as Map<String, dynamic>?;
        if (address != null) {
          final List<String> addressParts = [];
          
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
    
    final address = await reverseGeocode(position.latitude, position.longitude);
    if (mounted && selectedPin != null && selectedPin!.position == position) {
      setState(() {
        selectedPinAddress = address;
        isLoadingAddress = false;
      });
    }
  }
  
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
      
      final address = await reverseGeocode(position.latitude, position.longitude);
      if (mounted && activeInfoType == InfoType.currentLocation) {
        setState(() {
          currentLocationAddress = address;
          isLoadingAddress = false;
        });
      }
    }
  }

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
      
      int startIndex = 0;
      if (lines.isNotEmpty) {
        final firstLine = lines[0].trim();
        if (firstLine.toLowerCase().contains('mesh') || !RegExp(r'^\d').hasMatch(firstLine)) {
          startIndex = 1;
        }
      }
      
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
          }
        }
      }
      
      // 隣接セル処理を削除 - この部分を丸ごと削除
      
      setState(() {
        meshDataList = tempList;
        isLoading = false;
      });
      
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

  // getNeighborMeshCodes関数を削除 - 使用されなくなるため

  double calculateScore(int second, int sixth, int latest, int latestSingle) {
    double score = latest * 3.0 + sixth * 1.5 + second * 0.5;
    
    if (latestSingle > 0 && score > 0.5) {
      score -= 0.5;
    }
    
    return score;
  }

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

  Color getColorForScore(double score) {
    if (score == 0) {
      return Colors.transparent;
    }
    
    if (score > 0 && score < 2.0) {
      return Colors.green.withOpacity(heatmapOpacity);
    } 
    else if (score >= 2.0 && score < 4.0) {
      return Colors.yellow.withOpacity(heatmapOpacity);
    } 
    else if (score >= 4.0 && score < 5.0) {
      return Colors.orange.withOpacity(heatmapOpacity);
    } 
    else {
      return Colors.red.withOpacity(heatmapOpacity);
    }
  }

  String getLevelText(double score) {
    if (score == 0) return '安全';
    if (score > 0 && score < 2.0) return '低い';
    if (score >= 2.0 && score < 4.0) return '中程度';
    if (score >= 4.0 && score < 5.0) return 'やや高い';
    if (score >= 5.0) return '高い';
    return '安全';
  }

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
                  '本マップは環境省の公開データ等を基に作成しています。5kmメッシュ単位でのクマ出没危険度を予測表示しています。地域の参考情報としてご活用いただけます。',
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
                  '• 実際の状況は異なる場合があります。\n'
                  '• 本アプリの情報は参考情報としてご利用してください。\n'
                  '• 最新の情報は各自治体や関係機関にご確認ください。\n'
                  '• 野生動物との遭遇には十分ご注意ください。',
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
                  '熊の出没は、地域住民の安全や観光・農業に大きな影響を及ぼしています。'
                  '当サイト「くまもりマップ」では、最新の出没情報を集約し、わかりやすく危険度を表示しています。\n\n'
                  '自治体の皆さまと協力し、住民や観光客の安心・安全に役立つ仕組みづくりを進めています。\n'
                  'ご関心のある自治体様は、どうぞお気軽にご相談ください。',
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
                FlutterMap(
                  mapController: mapController,
                  options: MapOptions(
                    initialCenter: const LatLng(36.5, 138.0),
                    initialZoom: 6.0,
                    minZoom: 5.0,
                    maxZoom: 18.0,
                    interactionOptions: const InteractionOptions(
                      enableMultiFingerGestureRace: false,
                      rotationThreshold: 20.0,
                      rotationWinGestures: MultiFingerGesture.none,
                      pinchZoomThreshold: 0.5,
                      pinchMoveThreshold: 40.0,
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                    ),
                    onTap: (tapPosition, point) {
                      setPin(point);
                    },
                    onPositionChanged: (position, hasGesture) {
                      if (hasGesture) {
                        setState(() {});
                      }
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: tileProviders[selectedTileProvider].urlTemplate,
                      subdomains: tileProviders[selectedTileProvider].subdomains ?? const [],
                      userAgentPackageName: 'com.example.bear_watch',
                    ),
                    PolygonLayer(
                      polygons: meshDataList
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
                      
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        alignment: Alignment.centerRight,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.9),
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 4,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.update, size: 12, color: Colors.grey.shade500),
                              const SizedBox(width: 4),
                              Text(
                                '更新: $lastUpdated',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade500,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      
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
                
                Positioned(
                  right: 16,
                  bottom: MediaQuery.of(context).size.height * 0.32,
                  child: Column(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: Colors.white,
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
                          icon: const Icon(
                            Icons.share,
                            color: Colors.black87,
                            size: 24,
                          ),
                          onPressed: () => _showShareDialog(context),
                          padding: EdgeInsets.zero,
                        ),
                      ),
                      
                      const SizedBox(height: 12),
                      
                      Container(
                        width: 48,
                        height: 48,
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
                            size: 24,
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
                          padding: EdgeInsets.zero,
                        ),
                      ),
                      
                      const SizedBox(height: 12),
                      
                      Container(
                        width: 48,
                        height: 48,
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
                          icon: const Icon(
                            Icons.add, 
                            size: 24,
                          ),
                          onPressed: () {
                            final currentZoom = mapController.camera.zoom;
                            if (currentZoom < 18.0) {
                              mapController.move(
                                mapController.camera.center,
                                (currentZoom + 1).clamp(5.0, 18.0),
                              );
                            }
                          },
                          padding: EdgeInsets.zero,
                        ),
                      ),
                      
                      Container(
                        width: 48,
                        height: 1,
                        color: Colors.grey.shade300,
                      ),
                      
                      Container(
                        width: 48,
                        height: 48,
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
                          icon: const Icon(
                            Icons.remove, 
                            size: 24,
                          ),
                          onPressed: () {
                            final currentZoom = mapController.camera.zoom;
                            if (currentZoom > 5.0) {
                              mapController.move(
                                mapController.camera.center,
                                (currentZoom - 1).clamp(5.0, 18.0),
                              );
                            }
                          },
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                ),
                
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
                            Container(
                              margin: const EdgeInsets.symmetric(vertical: 12),
                              width: 40,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.grey[300],
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
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
                                        GestureDetector(
                                          onTap: () {
                                            setState(() {
                                              isSettingsPanelOpen = !isSettingsPanelOpen;
                                            });
                                          },
                                          child: Container(
                                            width: 40,
                                            height: 40,
                                            decoration: BoxDecoration(
                                              color: isSettingsPanelOpen 
                                                  ? Colors.brown.shade100 
                                                  : Colors.grey.shade100,
                                              borderRadius: BorderRadius.circular(20),
                                            ),
                                            child: Icon(
                                              FontAwesomeIcons.gear,
                                              size: 18,
                                              color: isSettingsPanelOpen 
                                                  ? Colors.brown.shade700 
                                                  : Colors.grey.shade600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  
                                  const SizedBox(height: 12),
                                  
                                  if (isSettingsPanelOpen)
                                    Container(
                                      margin: const EdgeInsets.only(bottom: 12),
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        color: Colors.brown.shade50,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: Colors.brown.shade200),
                                      ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Icon(Icons.map, size: 18, color: Colors.brown.shade700),
                                              const SizedBox(width: 8),
                                              Text(
                                                '地図スタイル',
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w600,
                                                  color: Colors.brown.shade800,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 12),
                                          Container(
                                            width: double.infinity,
                                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                            decoration: BoxDecoration(
                                              color: Colors.white,
                                              borderRadius: BorderRadius.circular(8),
                                              border: Border.all(color: Colors.brown.shade300),
                                            ),
                                            child: DropdownButtonHideUnderline(
                                              child: DropdownButton<int>(
                                                value: selectedTileProvider,
                                                onChanged: (int? value) {
                                                  if (value != null) {
                                                    setState(() {
                                                      selectedTileProvider = value;
                                                    });
                                                  }
                                                },
                                                items: tileProviders
                                                    .asMap()
                                                    .entries
                                                    .map((entry) => DropdownMenuItem<int>(
                                                          value: entry.key,
                                                          child: Row(
                                                            children: [
                                                              Icon(
                                                                _getIconForTileProvider(entry.key),
                                                                size: 20,
                                                                color: Colors.brown.shade600,
                                                              ),
                                                              const SizedBox(width: 8),
                                                              Text(
                                                                entry.value.name,
                                                                style: const TextStyle(fontSize: 14),
                                                              ),
                                                            ],
                                                          ),
                                                        ))
                                                    .toList(),
                                                icon: Icon(
                                                  Icons.arrow_drop_down,
                                                  color: Colors.brown.shade600,
                                                ),
                                                style: TextStyle(
                                                  color: Colors.brown.shade800,
                                                  fontSize: 14,
                                                ),
                                                isExpanded: true,
                                              ),
                                            ),
                                          ),
                                          
                                          const SizedBox(height: 20),
                                          
                                          Row(
                                            children: [
                                              Icon(Icons.opacity, size: 18, color: Colors.brown.shade700),
                                              const SizedBox(width: 8),
                                              Text(
                                                'ヒートマップ表示',
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w600,
                                                  color: Colors.brown.shade800,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 12),
                                          Row(
                                            children: [
                                              const Text(
                                                '不透明度',
                                                style: TextStyle(fontSize: 14, color: Colors.black87),
                                              ),
                                              const Spacer(),
                                              Text(
                                                '${(heatmapOpacity * 100).round()}%',
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  color: Colors.brown.shade700,
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
                                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
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
                                        
                                        LayoutBuilder(
                                          builder: (context, constraints) {
                                            final barWidth = constraints.maxWidth;
                                            final segmentWidth = barWidth / 5;
                                            
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
                                                      ? 'クマの出没報告がない地域です。'
                                                      : _getDisplayMeshData()!.score < 2.0
                                                          ? 'クマの出没報告は少ない地域ですが\n' '山に入る際は基本的な注意を心がけましょう。'
                                                          : _getDisplayMeshData()!.score < 4.0
                                                              ? '定期的にクマの出没報告がある地域です。\n' '山に入る際は十分に注意しましょう。'
                                                              : _getDisplayMeshData()!.score < 5.0
                                                                  ? '最近クマの出没報告がある地域です。\n' '山に入る際は十分に注意しましょう。'
                                                                  : '頻繁にクマの出没報告がある地域です。\n' '山や市街地との境界部でも十分な注意が必要です。',
                                                  style: const TextStyle(fontSize: 14, color: Colors.grey),
                                                  textAlign: TextAlign.center,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ] else ...[
                                          Center(
                                            child: Column(
                                              children: [
                                                Text(
                                                  '安全',
                                                  style: TextStyle(
                                                    fontSize: 20,
                                                    fontWeight: FontWeight.bold,
                                                    color: Colors.cyan,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  'スコア: 0.00',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.grey,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                const Text(
                                                  'クマ出没の報告がない地域です',
                                                  style: TextStyle(fontSize: 14, color: Colors.grey),
                                                  textAlign: TextAlign.center,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  
                                  const SizedBox(height: 16),

                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton(
                                          onPressed: () => _showUsageDialog(context),
                                          style: OutlinedButton.styleFrom(
                                            padding: EdgeInsets.symmetric(vertical: 12),
                                            side: BorderSide(color: Colors.brown.shade300),
                                            foregroundColor: Colors.brown.shade700,
                                          ),
                                          child: Text('ご利用にあたって'),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: OutlinedButton(
                                          onPressed: () => _showMunicipalDialog(context),
                                          style: OutlinedButton.styleFrom(
                                            padding: EdgeInsets.symmetric(vertical: 12),
                                            side: BorderSide(color: Colors.blue.shade300),
                                            foregroundColor: Colors.blue.shade700,
                                          ),
                                          child: Text('自治体の皆様へ'),
                                        ),
                                      ),
                                    ],
                                  ),

                                  // Row(
                                  //   children: [
                                  //     Expanded(
                                  //       child: OutlinedButton.icon(
                                  //         onPressed: () => _showUsageDialog(context),
                                  //         icon: Icon(FontAwesomeIcons.circleInfo, size: 18),  // Material Icons.info_outline → FontAwesome
                                  //         label: Text('ご利用にあたって'),
                                  //         style: OutlinedButton.styleFrom(
                                  //           padding: EdgeInsets.symmetric(vertical: 12),
                                  //           side: BorderSide(color: Colors.brown.shade300),
                                  //           foregroundColor: Colors.brown.shade700,
                                  //         ),
                                  //       ),
                                  //     ),
                                  //     const SizedBox(width: 12),
                                  //     Expanded(
                                  //       child: OutlinedButton.icon(
                                  //         onPressed: () => _showMunicipalDialog(context),
                                  //         icon: Icon(FontAwesomeIcons.building, size: 18),  // Material Icons.business → FontAwesome
                                  //         label: Text('自治体の皆様へ'),
                                  //         style: OutlinedButton.styleFrom(
                                  //           padding: EdgeInsets.symmetric(vertical: 12),
                                  //           side: BorderSide(color: Colors.blue.shade300),
                                  //           foregroundColor: Colors.blue.shade700,
                                  //         ),
                                  //       ),
                                  //     ),
                                  //   ],
                                  // ),
                                  
                                  // Row(
                                  //   children: [
                                  //     Expanded(
                                  //       child: OutlinedButton.icon(
                                  //         onPressed: () => _showUsageDialog(context),
                                  //         icon: Icon(Icons.info_outline, size: 18),
                                  //         label: Text('ご利用にあたって'),
                                  //         style: OutlinedButton.styleFrom(
                                  //           padding: EdgeInsets.symmetric(vertical: 12),
                                  //           side: BorderSide(color: Colors.brown.shade300),
                                  //           foregroundColor: Colors.brown.shade700,
                                  //         ),
                                  //       ),
                                  //     ),
                                  //     const SizedBox(width: 12),
                                  //     Expanded(
                                  //       child: OutlinedButton.icon(
                                  //         onPressed: () => _showMunicipalDialog(context),
                                  //         icon: Icon(Icons.business, size: 18),
                                  //         label: Text('自治体の皆様へ'),
                                  //         style: OutlinedButton.styleFrom(
                                  //           padding: EdgeInsets.symmetric(vertical: 12),
                                  //           side: BorderSide(color: Colors.blue.shade300),
                                  //           foregroundColor: Colors.blue.shade700,
                                  //         ),
                                  //       ),
                                  //     ),
                                  //   ],
                                  // ),

                                  const SizedBox(height: 20),
                                ],
                              ),
                            ),
                            
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                              decoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(
                                    color: Colors.grey.shade200,
                                    width: 1,
                                  ),
                                ),
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    '© 2025 くまもりマップ',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.grey.shade500,
                                      fontWeight: FontWeight.w400,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'All rights reserved.',
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: Colors.grey.shade400,
                                      fontWeight: FontWeight.w300,
                                    ),
                                    textAlign: TextAlign.center,
                                   ),
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

  LatLng _getDisplayPosition() {
    if (activeInfoType == InfoType.currentLocation && currentPosition != null) {
      return LatLng(currentPosition!.latitude, currentPosition!.longitude);
    } else if (selectedPin != null) {
      return selectedPin!.position;
    }
    return const LatLng(0, 0);
  }
  
  MeshData? _getDisplayMeshData() {
    if (activeInfoType == InfoType.currentLocation) {
      return currentLocationMeshData;
    } else if (selectedPin != null) {
      return selectedPin!.meshData;
    }
    return null;
  }
  
  String? _getDisplayAddress() {
    if (activeInfoType == InfoType.currentLocation) {
      return currentLocationAddress;
    } else if (selectedPin != null) {
      return selectedPinAddress;
    }
    return null;
  }
}

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
