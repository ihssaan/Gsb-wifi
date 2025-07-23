import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as parser;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io';
import 'package:logger/logger.dart';

void main() {
  HttpOverrides.global = MyHttpOverrides(); // SSL hatalarını yoksay
  runApp(const OturumuYoneticiApp());
}

// SSL sertifikası doğrulama hatalarını bypass etmek için
class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

class OturumuYoneticiApp extends StatelessWidget {
  const OturumuYoneticiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GSB WiFi Giriş Sistemi',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
        ),
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MainScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class Account {
  final String id;
  final String username;
  final String password;

  Account({required this.id, required this.username, required this.password});

  factory Account.fromJson(String id, Map<String, dynamic> json) {
    return Account(
      id: id,
      username: json['username'] as String,
      password: json['password'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'username': username,
      'password': password,
    };
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final Logger logger = Logger();
  List<Account> accounts = [];
  String? selectedAccountId;
  bool isLoading = false;
  String loadingMessage = "İşlem yapılıyor...";
  http.Client? session;

  @override
  void initState() {
    super.initState();
    loadAccounts();
  }

  Future<void> loadAccounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final accountsJson = prefs.getString('accounts') ?? '{}';
      final Map<String, dynamic> accountsMap = json.decode(accountsJson);

      setState(() {
        accounts = accountsMap.entries
            .map((entry) => Account.fromJson(entry.key, entry.value))
            .toList();
      });

      logger.i("Toplam ${accounts.length} hesap yüklendi");
    } catch (e) {
      logger.e("Hesaplar yüklenirken hata oluştu: $e");
      showSnackBar("Hesaplar yüklenirken hata oluştu!");
    }
  }

  Future<void> saveAccounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      Map<String, dynamic> accountsMap = {};

      for (var account in accounts) {
        accountsMap[account.id] = account.toJson();
      }

      await prefs.setString('accounts', json.encode(accountsMap));
    } catch (e) {
      logger.e("Hesaplar kaydedilirken hata oluştu: $e");
      showSnackBar("Hesaplar kaydedilirken hata oluştu!");
    }
  }

  void selectAccount(String id) {
    setState(() {
      selectedAccountId = id;
    });
    showSnackBar(
        "Seçilen hesap: ${accounts.firstWhere((account) => account.id == id).username}");
  }

  Future<http.Response?> handleLogin(http.Client client, String username, String password, Map<String, String> headers, {int maxRetries = 3}) async {
    int retryCount = 0;
    http.Response? response;

    while (retryCount < maxRetries) {
      try {
        logger.i("Giriş denemesi #${retryCount + 1} başlatılıyor...");

        // Giriş verileri
        Map<String, String> loginData = {
          'j_username': username.trim(),
          'j_password': password.trim(),
          'submit': 'Giriş'
        };

        logger.i("Giriş verileri: ${loginData.toString()}");
        logger.i("İlk giriş isteği gönderiliyor...");
        var response = await client.post(
          Uri.parse('https://wifi.gsb.gov.tr/j_spring_security_check'),
          headers: headers,
          body: loginData,
        ).timeout(const Duration(seconds: 60));

        logger.i("İlk giriş yanıtı - Durum Kodu: ${response.statusCode}");
        logger.i("Gönderilen headers: ${headers.toString()}");

        // Yönlendirmeleri kontrol et
        if (response.statusCode == 302) {
          final redirectUrl = response.headers['location'];
          logger.i("Yönlendirme algılandı: $redirectUrl");

          // Diğer yönlendirmeleri takip et
          final fullUrl = redirectUrl!.startsWith('http') 
              ? redirectUrl 
              : 'https://wifi.gsb.gov.tr${redirectUrl.startsWith('/') ? redirectUrl : '/$redirectUrl'}';

          response = await http.get(
            Uri.parse(fullUrl),
            headers: headers,
          ).timeout(const Duration(seconds: 60));

          if (response.statusCode == 200) {
            return response;
          }
        }

        // Eğer başarılı bir yanıt aldıysak döngüden çık
        if (response.statusCode == 200) {
          return response;
        }

        // Başarısız olursa tekrar dene
        retryCount++;
        if (retryCount < maxRetries) {
          logger.w("Giriş başarısız oldu, 5 saniye sonra tekrar deneniyor... (Deneme ${retryCount + 1}/$maxRetries)");
          setState(() {
            loadingMessage = "Giriş başarısız, tekrar deneniyor... (${retryCount + 1}/$maxRetries)";
          });
          await Future.delayed(const Duration(seconds: 5));
        }
      } catch (e) {
        logger.e("Giriş denemesi #${retryCount + 1} hatası: $e");
        retryCount++;
        if (retryCount < maxRetries) {
          logger.w("Hata oluştu, 5 saniye sonra tekrar deneniyor... (Deneme ${retryCount + 1}/$maxRetries)");
          setState(() {
            loadingMessage = "Hata oluştu, tekrar deneniyor... (${retryCount + 1}/$maxRetries)";
          });
          await Future.delayed(const Duration(seconds: 5));
        }
      }
    }

    return response;
  }

  Future<void> login() async {
    if (selectedAccountId == null) {
      showSnackBar("Lütfen bir hesap seçin!");
      return;
    }

    final account = accounts.firstWhere((account) => account.id == selectedAccountId);
    final username = account.username;
    final password = account.password;

    logger.i("Giriş denemesi başlatılıyor: $username");
    setState(() {
      isLoading = true;
      loadingMessage = "Giriş yapılıyor...";
    });

    try {
      final client = http.Client();
      session = client;

      // Headers ekle
      Map<String, String> headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
        'Accept-Language': 'tr,en-US;q=0.9,en;q=0.8',
        'Accept-Encoding': 'gzip, deflate, br',
        'Connection': 'keep-alive',
        'Upgrade-Insecure-Requests': '1'
      };

      // İlk giriş isteği
      Map<String, String> loginData = {
        'j_username': username.trim(),
        'j_password': password.trim(),
        'submit': 'Giriş'
      };

      logger.i("Giriş verileri: ${loginData.toString()}");
      logger.i("İlk giriş isteği gönderiliyor...");
      var response = await client.post(
        Uri.parse('https://wifi.gsb.gov.tr/j_spring_security_check'),
        headers: headers,
        body: loginData,
      ).timeout(const Duration(seconds: 60));

      logger.i("İlk giriş yanıtı - Durum Kodu: ${response.statusCode}");
      
      // 302 yönlendirmesini takip et
      if (response.statusCode == 302) {
        final redirectUrl = response.headers['location'];
        logger.i("Yönlendirme algılandı: $redirectUrl");

        if (redirectUrl != null) {
          final fullUrl = redirectUrl.startsWith('http') 
              ? redirectUrl 
              : 'https://wifi.gsb.gov.tr${redirectUrl.startsWith('/') ? redirectUrl : '/$redirectUrl'}';

          // Ana sayfaya GET isteği yap
          response = await client.get(
            Uri.parse(fullUrl),
            headers: headers,
          ).timeout(const Duration(seconds: 60));

          logger.i("Ana sayfa yanıtı - Durum Kodu: ${response.statusCode}");
          logger.i("Ana sayfa URL: ${response.request?.url}");

          // ViewState değerini al
          final document = parser.parse(response.body);
          final viewStateElement = document.querySelector('input[name="javax.faces.ViewState"]');
          final viewState = viewStateElement?.attributes['value'];

          if (viewState != null) {
            logger.i("Ana sayfa ViewState değeri: $viewState");
          }
        }
      }
      
      // 3 saniye bekle
      await Future.delayed(const Duration(seconds: 3));

      // Maksimum cihaz sayfasına git
      setState(() {
        loadingMessage = "Maksimum cihaz sayfasına yönlendiriliyor...";
      });
      
      logger.i("Maksimum cihaz sayfasına GET isteği yapılıyor...");
      
      // Önce GET isteği yap
      response = await client.get(
        Uri.parse('https://wifi.gsb.gov.tr/maksimumCihazHakkiDolu.html'),
        headers: headers,
      ).timeout(const Duration(seconds: 60));

      logger.i("Maksimum cihaz sayfası GET yanıtı - Durum Kodu: ${response.statusCode}");
      logger.i("Maksimum cihaz sayfası URL: ${response.request?.url}");

      // Yönlendirmeleri takip et
      if (response.statusCode == 302) {
        final redirectUrl = response.headers['location'];
        logger.i("Maksimum cihaz sayfası yönlendirmesi algılandı: $redirectUrl");

        if (redirectUrl != null) {
          final fullUrl = redirectUrl.startsWith('http') 
              ? redirectUrl 
              : 'https://wifi.gsb.gov.tr${redirectUrl.startsWith('/') ? redirectUrl : '/$redirectUrl'}';

          // 2 saniye bekle
          await Future.delayed(const Duration(seconds: 2));

          // Yönlendirmeyi takip et
          response = await client.get(
            Uri.parse(fullUrl),
            headers: headers,
          ).timeout(const Duration(seconds: 60));

          logger.i("Maksimum cihaz sayfası yönlendirme sonrası - Durum Kodu: ${response.statusCode}");
          logger.i("Maksimum cihaz sayfası yönlendirme sonrası URL: ${response.request?.url}");
        }
      }

      // 2 saniye bekle
      await Future.delayed(const Duration(seconds: 2));

      // Şimdi POST isteği yap
      logger.i("Maksimum cihaz sayfasına POST isteği yapılıyor...");
      
      // Maksimum cihaz sayfası için POST verileri
      Map<String, String> maksimumCihazData = {
        'j_username': username,
        'j_password': password
      };

      response = await client.post(
        Uri.parse('https://wifi.gsb.gov.tr/maksimumCihazHakkiDolu.html'),
        headers: headers,
        body: maksimumCihazData,
      ).timeout(const Duration(seconds: 60));

      logger.i("Maksimum cihaz sayfası POST yanıtı - Durum Kodu: ${response.statusCode}");

      if (response.statusCode == 200) {
        final document = parser.parse(response.body);
        final viewStateElement = document.querySelector('input[name="javax.faces.ViewState"]');
        final viewState = viewStateElement?.attributes['value'];

        if (viewState != null) {
          logger.i("ViewState değeri bulundu: $viewState");

          // Ajax headers
          Map<String, String> ajaxHeaders = {
            'faces-request': 'partial/ajax',
            'x-requested-with': 'XMLHttpRequest',
            'content-type': 'application/x-www-form-urlencoded; charset=UTF-8',
            'Accept': 'application/xml, text/xml, */*; q=0.01',
            'Referer': 'https://wifi.gsb.gov.tr/maksimumCihazHakkiDolu.html',
            ...headers
          };

          // Oturum sonlandırma verileri
          Map<String, String> logoutData = {
            'javax.faces.partial.ajax': 'true',
            'javax.faces.source': 'j_idt36',
            'javax.faces.partial.execute': '@all',
            'javax.faces.partial.render': '@all',
            'j_idt36': 'j_idt36',
            'javax.faces.ViewState': viewState,
            'javax.faces.behavior.event': 'action',
            'javax.faces.partial.event': 'click'
          };

          logger.i("Oturum sonlandırma verileri: ${logoutData.toString()}");
          setState(() {
            loadingMessage = "Oturum sonlandırılıyor...";
          });

          // Oturum sonlandırma isteği
          logger.i("Oturum sonlandırma isteği gönderiliyor...");
          response = await client.post(
            Uri.parse('https://wifi.gsb.gov.tr/maksimumCihazHakkiDolu.html'),
            headers: ajaxHeaders,
            body: logoutData,
          ).timeout(const Duration(seconds: 60));

          logger.i("Oturum sonlandırma yanıtı - Durum Kodu: ${response.statusCode}");
          logger.i("Oturum sonlandırma yanıt içeriği: ${response.body}");

          // Oturum sonlandırma başarılı mı kontrol et
          if (response.body.contains("Aktif Oturum Bulunamadı")) {
            logger.i("Oturum başarıyla sonlandırıldı, 10 saniye bekleniyor...");
            // 10 saniye bekle
            setState(() {
              loadingMessage = "Oturum sonlandırma işlemi bekleniyor... (10 saniye)";
            });
            await Future.delayed(const Duration(seconds: 10));

            // Logout endpoint'ine istek yap
            logger.i("Logout isteği gönderiliyor...");
            response = await client.get(
              Uri.parse('https://wifi.gsb.gov.tr/logout'),
              headers: headers,
            ).timeout(const Duration(seconds: 60));

            logger.i("Logout yanıtı - Durum Kodu: ${response.statusCode}");

            // 10 saniye daha bekle
            setState(() {
              loadingMessage = "Son giriş için hazırlanıyor... (10 saniye)";
            });
            await Future.delayed(const Duration(seconds: 10));

            // Sayfayı yenile
            logger.i("Ana sayfa yenileniyor...");
            response = await client.get(
              Uri.parse('https://wifi.gsb.gov.tr/'),
              headers: headers,
            ).timeout(const Duration(seconds: 60));

            logger.i("Ana sayfa yenileme yanıtı - Durum Kodu: ${response.statusCode}");

            // 5 saniye bekle
            setState(() {
              loadingMessage = "Son hazırlıklar yapılıyor... (5 saniye)";
            });
            await Future.delayed(const Duration(seconds: 5));

            // Son giriş isteği
            setState(() {
              loadingMessage = "Yeniden giriş yapılıyor...";
            });

            logger.i("Son giriş isteği gönderiliyor...");
            response = await client.post(
              Uri.parse('https://wifi.gsb.gov.tr/j_spring_security_check'),
              headers: headers,
              body: loginData,
            ).timeout(const Duration(seconds: 60));

            logger.i("Son giriş yanıtı - Durum Kodu: ${response.statusCode}");

            // Yönlendirmeyi takip et
            if (response.statusCode == 302) {
              final redirectUrl = response.headers['location'];
              logger.i("Son giriş yönlendirmesi: $redirectUrl");

              if (redirectUrl != null) {
                final fullUrl = redirectUrl.startsWith('http') 
                    ? redirectUrl 
                    : 'https://wifi.gsb.gov.tr${redirectUrl.startsWith('/') ? redirectUrl : '/$redirectUrl'}';

                response = await client.get(
                  Uri.parse(fullUrl),
                  headers: headers,
                ).timeout(const Duration(seconds: 60));

                logger.i("Son yönlendirme yanıtı - Durum Kodu: ${response.statusCode}");
                logger.i("Son yönlendirme URL: ${response.request?.url}");

                // Gerçek bağlantı durumunu kontrol et
                try {
                  logger.i("Bağlantı durumu kontrol ediliyor...");
                  final testResponse = await client.get(
                    Uri.parse('http://connectivitycheck.gstatic.com/generate_204'),
                    headers: headers,
                  ).timeout(const Duration(seconds: 10));

                  if (testResponse.statusCode == 204) {
                    logger.i("İnternet bağlantısı aktif!");
                    setState(() {
                      isLoading = false;
                    });
                    showSnackBar("Giriş başarılı! WiFi bağlantınız hazır.");
                    return;
                  } else {
                    logger.e("İnternet bağlantısı yok! Durum kodu: ${testResponse.statusCode}");
                    setState(() {
                      isLoading = false;
                    });
                    showSnackBar("Giriş başarısız! İnternet bağlantısı sağlanamadı.");
                    return;
                  }
                } catch (e) {
                  logger.e("Bağlantı kontrolü hatası: $e");
                  setState(() {
                    isLoading = false;
                  });
                  showSnackBar("Giriş başarısız! İnternet bağlantısı kontrol edilemedi.");
                  return;
                }
              }
            }
          } else {
            logger.e("ViewState değeri bulunamadı!");
            setState(() {
              isLoading = false;
            });
            showSnackBar("ViewState değeri bulunamadı! Lütfen tekrar deneyin.");
            return;
          }
        }

        setState(() {
          isLoading = false;
        });
        showSnackBar("Giriş başarısız oldu. Lütfen tekrar deneyin.");

      }

    } catch (e) {
      logger.e("Giriş hatası: $e");
      String errorMessage = "Beklenmeyen bir hata oluştu!";

      if (e is SocketException) {
        errorMessage = "Bağlantı hatası oluştu. Lütfen internet bağlantınızı kontrol ediniz.";
      } else if (e is HttpException) {
        errorMessage = "HTTP İsteği hatası! Sunucu yanıt vermiyor.";
      } else if (e is FormatException) {
        errorMessage = "Geçersiz yanıt formatı! Sunucu hatalı yanıt döndü.";
      } else if (e is TimeoutException) {
        errorMessage = "Sunucu yanıt vermiyor! İstek zaman aşımına uğradı.";
      }

      setState(() {
        isLoading = false;
      });

      showSnackBar(errorMessage);
    }
  }

  Future<void> logout() async {
    if (selectedAccountId == null) {
      showSnackBar("Lütfen bir hesap seçin!");
      return;
    }

    final account =
        accounts.firstWhere((account) => account.id == selectedAccountId);
    final username = account.username;
    final password = account.password;

    logger.i("Çıkış denemesi başlatılıyor: $username");
    setState(() {
      isLoading = true;
      loadingMessage = "Oturum sonlandırılıyor...";
    });

    try {
      // HTTP istemcisi oluştur
      final client = http.Client();

      // Headers hazırla
      Map<String, String> headers = {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
        'Accept-Language': 'tr,en-US;q=0.9,en;q=0.8',
        'Connection': 'keep-alive',
        'Upgrade-Insecure-Requests': '1'
      };

      // Giriş verileri
      Map<String, String> loginData = {
        'j_username': username,
        'j_password': password,
        'submit': 'Giriş'
      };

      setState(() {
        loadingMessage = "Çıkış için önce giriş yapılıyor...";
      });
      logger.i("Çıkış için önce giriş yapılıyor...");

      // Önce giriş yap
      final loginResponse = await client.post(
        Uri.parse('https://wifi.gsb.gov.tr/j_spring_security_check'),
        headers: headers,
        body: loginData,
      ).timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          throw TimeoutException('Sunucu yanıt vermiyor! İstek zaman aşımına uğradı.');
        },
      );

      logger.i("Giriş yanıtı - Durum Kodu: ${loginResponse.statusCode}");

      if (loginResponse.statusCode == 200) {
        final responseUrl = loginResponse.request?.url.toString() ?? '';

        if (!responseUrl.contains("j_spring_security_check")) {
          setState(() {
            loadingMessage = "Giriş başarılı, oturum sonlandırılıyor...";
          });
          logger.i("Giriş başarılı, oturum sonlandırma işlemi devam ediyor...");

          // Maksimum cihaz sayfasını kontrol et
          setState(() {
            loadingMessage = "Cihaz bağlantıları kontrol ediliyor...";
          });
          logger.i("Maksimum cihaz sayfasına erişiliyor...");

          final maksimumCihazResponse = await client.get(
            Uri.parse('https://wifi.gsb.gov.tr/maksimumCihazHakkiDolu.html'),
            headers: headers,
          );

          logger.i(
              "Maksimum cihaz sayfası yanıtı - Durum Kodu: ${maksimumCihazResponse.statusCode}");

          if (maksimumCihazResponse.statusCode == 200) {
            setState(() {
              loadingMessage = "Bağlantı bilgileri alınıyor...";
            });
            logger.i("Maksimum cihaz sayfası yüklendi, ViewState aranıyor...");

            // ViewState değerini bul
            final document = parser.parse(maksimumCihazResponse.body);
            final viewStateElement =
                document.querySelector('input[name="javax.faces.ViewState"]');
            final viewState = viewStateElement?.attributes['value'];

            if (viewState != null) {
              logger.i("ViewState bulundu: $viewState");

              // Ajax headers
              Map<String, String> ajaxHeaders = {
                'faces-request': 'partial/ajax',
                'x-requested-with': 'XMLHttpRequest',
                'content-type':
                    'application/x-www-form-urlencoded; charset=UTF-8',
                ...headers
              };

              // Oturum sonlandırma verileri
              Map<String, String> logoutData = {
                'javax.faces.partial.ajax': 'true',
                'javax.faces.source': 'j_idt20:0:j_idt28:j_idt29',
                'javax.faces.partial.execute': '@all',
                'javax.faces.partial.render': '@all',
                'j_idt20:0:j_idt28:j_idt29': 'j_idt20:0:j_idt28:j_idt29',
                'j_idt20:0:j_idt28': 'j_idt20:0:j_idt28',
                'javax.faces.ViewState': viewState
              };

              setState(() {
                loadingMessage = "Oturum sonlandırma isteği gönderiliyor...";
              });
              logger.i("Oturum sonlandırma isteği gönderiliyor...");

              // Oturum sonlandırma isteği
              final logoutResponse = await client.post(
                Uri.parse(
                    'https://wifi.gsb.gov.tr/maksimumCihazHakkiDolu.html'),
                headers: ajaxHeaders,
                body: logoutData,
              );

              logger.i(
                  "Oturum sonlandırma yanıtı - Durum Kodu: ${logoutResponse.statusCode}");

              if (logoutResponse.statusCode == 200) {
                setState(() {
                  loadingMessage =
                      "Oturum sonlandırıldı, son işlemler yapılıyor...";
                });
                logger.i(
                    "Oturum sonlandırma isteği başarılı, 2 saniye bekleniyor...");

                // 2 saniye bekle
                await Future.delayed(const Duration(seconds: 2));

                // Çıkış yap
                final finalLogout = await client.get(
                  Uri.parse('https://wifi.gsb.gov.tr/logout'),
                  headers: headers,
                );

                logger.i(
                    "Final çıkış yanıtı - Durum Kodu: ${finalLogout.statusCode}");

                if (finalLogout.statusCode == 200 ||
                    finalLogout.statusCode == 302) {
                  // Oturumun gerçekten kapandığını kontrol et
                  try {
                    logger.i("Oturum durumu kontrol ediliyor...");
                    final testResponse = await client.get(
                      Uri.parse('http://connectivitycheck.gstatic.com/generate_204'),
                      headers: headers,
                    ).timeout(const Duration(seconds: 10));

                    if (testResponse.statusCode != 204) {
                      session = null;
                      logger.i("Oturum başarıyla sonlandırıldı - İnternet bağlantısı kesildi");
                      setState(() {
                        isLoading = false;
                      });
                      showSnackBar("Oturum başarıyla sonlandırıldı! WiFi bağlantınız kesildi.");
                    } else {
                      logger.w("Oturum sonlandırılamadı - İnternet bağlantısı hala aktif");
                      setState(() {
                        isLoading = false;
                      });
                      showSnackBar("Çıkış başarısız! İnternet bağlantısı hala aktif.");
                    }
                  } catch (e) {
                    logger.e("Oturum durumu kontrol hatası: $e");
                    setState(() {
                      isLoading = false;
                    });
                    showSnackBar("Çıkış durumu belirlenemedi! Lütfen bağlantınızı kontrol edin.");
                  }
                } else {
                  logger.w("Final çıkış başarısız");
                  setState(() {
                    isLoading = false;
                  });
                  showSnackBar("Çıkış başarısız! Lütfen tekrar deneyin.");
                }
              } else {
                logger.w("Oturum sonlandırma isteği başarısız");
                setState(() {
                  isLoading = false;
                });
                showSnackBar(
                    "Oturum sonlandırma isteği başarısız! Lütfen tekrar deneyin.");
              }
            } else {
              logger.w("ViewState değeri bulunamadı");
              setState(() {
                isLoading = false;
              });
              showSnackBar(
                  "ViewState değeri bulunamadı! Lütfen tekrar deneyin.");
            }
          } else {
            logger.w("Maksimum cihaz sayfasına erişilemedi");
            setState(() {
              isLoading = false;
            });
            showSnackBar(
                "Maksimum cihaz sayfasına erişilemedi! WiFi sisteminde bir sorun olabilir.");
          }
        } else {
          logger.w("Giriş başarısız, çıkış yapılamıyor");
          setState(() {
            isLoading = false;
          });
          showSnackBar(
              "Çıkış başarısız! Kullanıcı adı veya şifre hatalı olabilir.");
        }
      } else {
        logger.w("Giriş başarısız. Durum Kodu: ${loginResponse.statusCode}");
        setState(() {
          isLoading = false;
        });
        showSnackBar(
            "Çıkış başarısız! Durum Kodu: ${loginResponse.statusCode}. Lütfen tekrar deneyin.");
      }
    } catch (e) {
      logger.e("Çıkış hatası: $e");
      String errorMessage = "Beklenmeyen bir hata oluştu!";

      if (e is SocketException) {
        errorMessage =
            "Sunucuya bağlanılamadı! İnternet bağlantınızı kontrol edin.";
      } else if (e is HttpException) {
        errorMessage = "HTTP İsteği hatası! Sunucu yanıt vermiyor.";
      } else if (e is FormatException) {
        errorMessage = "Geçersiz yanıt formatı! Sunucu hatalı yanıt döndü.";
      } else if (e is TimeoutException) {
        errorMessage = "Sunucu yanıt vermiyor! İstek zaman aşımına uğradı.";
      }

      setState(() {
        isLoading = false;
      });

      showSnackBar(errorMessage);
    }
  }

  void showAddAccountDialog() {
    final TextEditingController usernameController = TextEditingController();
    final TextEditingController passwordController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Yeni Hesap Ekle"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: usernameController,
              decoration: const InputDecoration(
                labelText: "TC Kimlik No",
                hintText: "TC Kimlik numaranızı girin",
              ),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: passwordController,
              decoration: const InputDecoration(
                labelText: "Şifre",
                hintText: "Şifrenizi girin",
              ),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("İptal"),
          ),
          TextButton(
            onPressed: () {
              final username = usernameController.text.trim();
              final password = passwordController.text.trim();

              if (username.isNotEmpty && password.isNotEmpty) {
                saveAccount(username, password);
                Navigator.pop(context);
              } else {
                showSnackBar("Lütfen tüm alanları doldurun!");
              }
            },
            child: const Text("Kaydet"),
          ),
        ],
      ),
    );
  }

  void saveAccount(String username, String password) {
    logger.i("Yeni hesap ekleniyor: $username");

    final newAccount = Account(
      id: "account_${DateTime.now().millisecondsSinceEpoch}",
      username: username,
      password: password,
    );

    setState(() {
      accounts.add(newAccount);
      selectedAccountId = newAccount.id;
    });

    saveAccounts();
    showSnackBar("Hesap başarıyla kaydedildi!");
    logger.i("Hesap eklendi: $username");
  }

  void deleteAccount(String id) {
    final account = accounts.firstWhere((account) => account.id == id);
    logger.i("Hesap siliniyor: ${account.username}");

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Hesap Silme"),
        content: Text(
            "${account.username} hesabını silmek istediğinize emin misiniz?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("İptal"),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                accounts.removeWhere((account) => account.id == id);
                if (selectedAccountId == id) {
                  selectedAccountId = null;
                }
              });
              saveAccounts();
              showSnackBar("Hesap başarıyla silindi!");
              logger.i("Hesap silindi: ${account.username}");
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(
              foregroundColor: Colors.red,
            ),
            child: const Text("Sil"),
          ),
        ],
      ),
    );
  }

  void showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("GSB WiFi Giriş Sistemi"),
      ),
      body: Stack(
        children: [
          // Ana içerik
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Seçili hesap bilgisi
                Container(
                  padding: const EdgeInsets.all(8.0),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(8.0),
                  ),
                  child: Text(
                    "Seçili Hesap: ${selectedAccountId != null ? accounts.firstWhere((account) => account.id == selectedAccountId).username : 'Yok'}",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey[800],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Hesap listesi
                Expanded(
                  child: accounts.isEmpty
                      ? Center(
                          child: Text(
                            "Henüz hesap eklenmemiş",
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey[600],
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: accounts.length,
                          itemBuilder: (context, index) {
                            final account = accounts[index];
                            final isSelected = account.id == selectedAccountId;

                            return Card(
                              elevation: 2,
                              color: isSelected ? Colors.blue[100] : null,
                              margin: const EdgeInsets.symmetric(vertical: 5),
                              child: ListTile(
                                leading: Icon(
                                  Icons.account_circle,
                                  color: isSelected
                                      ? Colors.blue[800]
                                      : Colors.grey[700],
                                  size: 36,
                                ),
                                title: Text(
                                  account.username,
                                  style: TextStyle(
                                    fontWeight: isSelected
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                                subtitle: Text(
                                  "●●●●●●●●●●",
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                  ),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.delete),
                                      color: Colors.red[400],
                                      onPressed: () =>
                                          deleteAccount(account.id),
                                    ),
                                  ],
                                ),
                                onTap: () => selectAccount(account.id),
                              ),
                            );
                          }),
                ),

                const SizedBox(height: 16),

// İşlem butonları
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.login),
                        label: const Text("Giriş Yap"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: isLoading ? null : login,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.logout),
                        label: const Text("Çıkış Yap"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: isLoading ? null : logout,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                ElevatedButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text("Yeni Hesap Ekle"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: isLoading ? null : showAddAccountDialog,
                ),
              ],
            ),
          ),

// Yükleniyor göstergesi
          if (isLoading)
            Container(
              color: Colors.black.withOpacity(0.5),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(
                      color: Colors.white,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      loadingMessage,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    // HTTP istemcisini kapat
    session?.close();
    super.dispose();
  }
}
