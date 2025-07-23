from kivymd.app import MDApp
from kivymd.uix.screen import MDScreen
from kivymd.uix.button import MDRaisedButton, MDIconButton
from kivymd.uix.textfield import MDTextField
from kivymd.uix.list import OneLineListItem, OneLineIconListItem
from kivymd.uix.dialog import MDDialog
from kivymd.uix.boxlayout import MDBoxLayout
from kivy.uix.scrollview import ScrollView
from kivy.storage.jsonstore import JsonStore
from kivymd.theming import ThemeManager
from kivymd.uix.spinner import MDSpinner
from kivymd.uix.label import MDLabel
from kivymd.uix.card import MDCard
from kivy.core.window import Window
from kivy.metrics import dp
from kivy.clock import Clock
import requests
from bs4 import BeautifulSoup
import urllib3
import time
import os
import logging

# Loglama ayarları
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)

# SSL uyarılarını devre dışı bırak
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

class OturumuYonetici(MDApp):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.store = JsonStore('accounts.json')
        self.current_account = None
        self.session = None
        self.theme_cls = ThemeManager()
        self.theme_cls.primary_palette = "Blue"
        self.theme_cls.theme_style = "Light"
        self.loading_overlay = None
        self.loading_spinner = None
        self.loading_label = None
        logging.info("Uygulama başlatıldı")

    def build(self):
        self.root = MDScreen()
        
        # Ana ekranı oluştur
        self.main_screen = self.create_main_screen()
        self.root.add_widget(self.main_screen)
        
        return self.root

    def create_main_screen(self):
        screen = MDScreen()
        
        # Ana layout
        layout = MDBoxLayout(orientation='vertical', padding=10, spacing=10, md_bg_color=(1, 1, 1, 1))
        
        # Başlık
        from kivymd.uix.label import MDLabel
        title = MDLabel(
            text="GSB WiFi Giriş Sistemi",
            halign="center",
            theme_text_color="Primary",
            font_style="H5",
            size_hint_y=None,
            height=50
        )
        layout.add_widget(title)
        
        # Seçili hesap bilgisi
        self.selected_account_label = MDLabel(
            text="Seçili Hesap: Yok",
            halign="center",
            theme_text_color="Secondary",
            size_hint_y=None,
            height=30
        )
        layout.add_widget(self.selected_account_label)
        
        # Hesap seçimi için ScrollView
        scroll = ScrollView()
        self.account_list = MDBoxLayout(orientation='vertical', size_hint_y=None, spacing=5)
        self.account_list.bind(minimum_height=self.account_list.setter('height'))
        
        # Kayıtlı hesapları yükle
        self.load_accounts()
        
        scroll.add_widget(self.account_list)
        layout.add_widget(scroll)
        
        # Yeni hesap ekle butonu
        add_button = MDRaisedButton(
            text="Yeni Hesap Ekle",
            size_hint=(1, None),
            height=50,
            on_release=self.show_add_account_dialog
        )
        layout.add_widget(add_button)
        
        # Giriş yap butonu
        login_button = MDRaisedButton(
            text="Giriş Yap",
            size_hint=(1, None),
            height=50,
            on_release=self.login
        )
        layout.add_widget(login_button)
        
        # Çıkış yap butonu
        logout_button = MDRaisedButton(
            text="Çıkış Yap",
            size_hint=(1, None),
            height=50,
            on_release=self.logout
        )
        layout.add_widget(logout_button)
        
        screen.add_widget(layout)
        return screen

    def show_loading(self, message="İşlem yapılıyor..."):
        if self.loading_overlay:
            self.hide_loading()
        
        # Sayfa boyutuna göre arka plan panel
        self.loading_overlay = MDCard(
            orientation="vertical",
            size_hint=(None, None),
            size=(dp(300), dp(200)),
            pos_hint={"center_x": 0.5, "center_y": 0.5},
            elevation=10,
            radius=[20, 20, 20, 20],
            padding=20
        )
        
        # Yüklenme göstergesi
        self.loading_spinner = MDSpinner(
            size_hint=(None, None),
            size=(dp(48), dp(48)),
            pos_hint={"center_x": 0.5},
            active=True
        )
        
        # Yüklenme mesajı
        self.loading_label = MDLabel(
            text=message,
            halign="center",
            theme_text_color="Primary",
            font_style="Body1"
        )
        
        # Bileşenleri ekle
        self.loading_overlay.add_widget(self.loading_spinner)
        self.loading_overlay.add_widget(self.loading_label)
        
        # Ana ekrana ekle
        self.root.add_widget(self.loading_overlay)
    
    def update_loading_message(self, message):
        if self.loading_label:
            self.loading_label.text = message
    
    def hide_loading(self):
        if self.loading_overlay:
            self.root.remove_widget(self.loading_overlay)
            self.loading_overlay = None
            self.loading_spinner = None
            self.loading_label = None

    def load_accounts(self):
        self.account_list.clear_widgets()
        for key in self.store.keys():
            account = self.store.get(key)
            # Her hesap için bir satır oluştur
            item = MDBoxLayout(orientation='horizontal', size_hint_y=None, height=50)
            
            # Hesap bilgisi
            account_text = OneLineListItem(
                text=f"{account['username']}",
                on_release=lambda x, key=key: self.select_account(key),
                bg_color=(0.8, 0.8, 1, 1) if key == self.current_account else (1, 1, 1, 1)
            )
            item.add_widget(account_text)
            
            # Silme butonu
            delete_button = MDIconButton(
                icon="delete",
                theme_text_color="Error",
                on_release=lambda x, key=key: self.show_delete_confirmation(key)
            )
            item.add_widget(delete_button)
            
            self.account_list.add_widget(item)
        logging.info(f"Toplam {len(self.store.keys())} hesap yüklendi")

    def show_delete_confirmation(self, key):
        account = self.store.get(key)
        logging.info(f"Hesap silme onayı isteniyor: {account['username']}")
        self.dialog = MDDialog(
            title="Hesap Silme",
            text=f"{account['username']} hesabını silmek istediğinize emin misiniz?",
            buttons=[
                MDRaisedButton(
                    text="İptal",
                    on_release=lambda x: self.dialog.dismiss()
                ),
                MDRaisedButton(
                    text="Sil",
                    theme_text_color="Error",
                    on_release=lambda x: self.delete_account(key)
                )
            ]
        )
        self.dialog.open()

    def delete_account(self, key):
        account = self.store.get(key)
        logging.info(f"Hesap siliniyor: {account['username']}")
        self.store.delete(key)
        self.dialog.dismiss()
        self.load_accounts()
        self.show_snackbar("Hesap başarıyla silindi!")
        if self.current_account == key:
            self.current_account = None
            self.selected_account_label.text = "Seçili Hesap: Yok"
        logging.info(f"Hesap silindi: {account['username']}")

    def select_account(self, key):
        account = self.store.get(key)
        self.current_account = key
        self.selected_account_label.text = f"Seçili Hesap: {account['username']}"
        self.load_accounts()  # Seçili hesabı vurgulamak için listeyi yeniden yükle
        logging.info(f"Hesap seçildi: {account['username']}")
        self.show_snackbar(f"Seçilen hesap: {account['username']}")

    def show_add_account_dialog(self, *args):
        logging.info("Yeni hesap ekleme penceresi açılıyor")
        content = MDBoxLayout(orientation='vertical', spacing=10, size_hint_y=None, height=120)
        
        username_field = MDTextField(
            hint_text="TC Kimlik No",
            helper_text="TC Kimlik numaranızı girin",
            helper_text_mode="on_focus"
        )
        
        password_field = MDTextField(
            hint_text="Şifre",
            helper_text="Şifrenizi girin",
            helper_text_mode="on_focus",
            password=True
        )
        
        content.add_widget(username_field)
        content.add_widget(password_field)
        
        self.dialog = MDDialog(
            title="Yeni Hesap Ekle",
            type="custom",
            content_cls=content,
            buttons=[
                MDRaisedButton(
                    text="İptal",
                    on_release=lambda x: self.dialog.dismiss()
                ),
                MDRaisedButton(
                    text="Kaydet",
                    on_release=lambda x: self.save_account(username_field.text, password_field.text)
                )
            ]
        )
        self.dialog.open()

    def save_account(self, username, password):
        if username and password:
            logging.info(f"Yeni hesap ekleniyor: {username}")
            key = f"account_{len(self.store)}"
            self.store.put(key, username=username, password=password)
            self.dialog.dismiss()
            self.load_accounts()
            self.show_snackbar("Hesap başarıyla kaydedildi!")
            logging.info(f"Hesap eklendi: {username}")
        else:
            logging.warning("Boş alanlarla hesap ekleme denemesi yapıldı")
            self.show_snackbar("Lütfen tüm alanları doldurun!")

    def show_error_dialog(self, title, message):
        """Hata mesajlarını göstermek için özel dialog"""
        # Önce yükleme ekranını kapat
        self.hide_loading()
        
        # Hata dialogu oluştur
        error_dialog = MDDialog(
            title=title,
            text=message,
            buttons=[
                MDRaisedButton(
                    text="Tamam",
                    on_release=lambda x: error_dialog.dismiss()
                )
            ],
            size_hint=(0.8, None)
        )
        error_dialog.open()

    def login(self, *args):
        if not self.current_account:
            logging.warning("Hesap seçilmeden giriş denemesi yapıldı")
            self.show_snackbar("Lütfen bir hesap seçin!")
            return
            
        account = self.store.get(self.current_account)
        username = account['username']
        password = account['password']
        
        logging.info(f"Giriş denemesi başlatılıyor: {username}")
        # Yükleme ekranını göster
        self.show_loading("Giriş yapılıyor...")
        
        try:
            # Doğrudan giriş denemesi yapalım, bağlantı kontrollerini atlayalım
            # Giriş işlemi
            session = requests.Session()
            session.verify = False
            
            # Headers ekle
            headers = {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36',
                'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
                'Accept-Language': 'tr,en-US;q=0.9,en;q=0.8',
                'Accept-Encoding': 'gzip, deflate, br',
                'Connection': 'keep-alive',
                'Upgrade-Insecure-Requests': '1'
            }
            
            session.headers.update(headers)
            
            # Giriş formunu doldurmak için gerekli veriler
            login_url = 'https://wifi.gsb.gov.tr/j_spring_security_check'
            login_data = {
                'j_username': username,
                'j_password': password,
                'submit': 'Giriş'
            }
            
            self.update_loading_message("Sunucuya bağlanılıyor...")
            logging.info("İlk giriş isteği gönderiliyor...")
            response = session.post(login_url, data=login_data, timeout=10)
            logging.info(f"Giriş yanıtı alındı - Durum Kodu: {response.status_code}")
            logging.info(f"Yanıt URL: {response.url}")
            
            if response.status_code == 200:
                if "j_spring_security_check" not in response.url:
                    self.update_loading_message("Giriş başarılı, cihaz kontrolü yapılıyor...")
                    logging.info("İlk giriş başarılı, maksimum cihaz kontrolü yapılıyor...")
                    
                    # Maksimum cihaz sayfasına yönlendirildiyse
                    maksimum_cihaz_url = 'https://wifi.gsb.gov.tr/maksimumCihazHakkiDolu.html'
                    maksimum_cihaz_response = session.get(maksimum_cihaz_url)
                    logging.info(f"Maksimum cihaz yanıtı - Durum Kodu: {maksimum_cihaz_response.status_code}")
        
                    if maksimum_cihaz_response.status_code == 200:
                        self.update_loading_message("Maksimum cihaz sayısına ulaşıldı, oturumlar kapatılıyor...")
                        logging.info("Maksimum cihaz sayfasına erişildi, ViewState aranıyor...")
                        
                        soup = BeautifulSoup(maksimum_cihaz_response.text, 'html.parser')
                        
                        # ViewState değerini bul
                        view_state_input = soup.find('input', {'name': 'javax.faces.ViewState'})
                        if view_state_input:
                            view_state = view_state_input.get('value')
                            logging.info(f"ViewState bulundu: {view_state}")
                            
                            # Oturum sonlandırma isteği için headers
                            ajax_headers = {
                                'faces-request': 'partial/ajax',
                                'x-requested-with': 'XMLHttpRequest',
                                'content-type': 'application/x-www-form-urlencoded; charset=UTF-8',
                            }
                            session.headers.update(ajax_headers)
                            
                            # Sonlandırma isteği için form verileri
                            logout_data = {
                                'javax.faces.partial.ajax': 'true',
                                'javax.faces.source': 'j_idt20:0:j_idt28:j_idt29',
                                'javax.faces.partial.execute': '@all',
                                'javax.faces.partial.render': '@all',
                                'j_idt20:0:j_idt28:j_idt29': 'j_idt20:0:j_idt28:j_idt29',
                                'j_idt20:0:j_idt28': 'j_idt20:0:j_idt28',
                                'javax.faces.ViewState': view_state
                            }
        
                            # Önce oturum sonlandırma isteği
                            self.update_loading_message("Oturum sonlandırılıyor...")
                            logging.info("Oturum sonlandırma isteği gönderiliyor...")
                            logout_response = session.post(
                                maksimum_cihaz_url,
                                data=logout_data
                            )
                            logging.info(f"Oturum sonlandırma yanıtı - Durum Kodu: {logout_response.status_code}")
                            
                            if logout_response.status_code == 200:
                                self.update_loading_message("Çıkış yapılıyor...")
                                logging.info("Oturum sonlandırma isteği başarılı, çıkış yapılıyor...")
                                
                                # Çıkış URL'sine yönlendir
                                final_logout = session.get('https://wifi.gsb.gov.tr/logout')
                                logging.info(f"Çıkış yanıtı - Durum Kodu: {final_logout.status_code}")
                                
                                # 302 veya 200 status code'unu kabul et
                                if final_logout.status_code in [302, 200]:
                                    self.update_loading_message("Yeniden giriş için hazırlanıyor...")
                                    logging.info("Oturum başarıyla sonlandırıldı, 3 saniye bekleniyor...")
                                    
                                    # 3 saniye bekle
                                    time.sleep(3)
                                    
                                    # Yeniden giriş yap
                                    self.update_loading_message("Yeniden giriş yapılıyor...")
                                    logging.info("Yeniden giriş yapılıyor...")
                                    session.headers.update(headers)  # Ajax headers'ı temizle
                                    login_response = session.post(login_url, data=login_data)
                                    logging.info(f"Yeniden giriş yanıtı - Durum Kodu: {login_response.status_code}")
                                    logging.info(f"Yeniden giriş URL: {login_response.url}")
                                    
                                    if login_response.status_code == 200 and "maksimumCihazHakkiDolu.html" not in login_response.url:
                                        self.session = session
                                        logging.info(f"Giriş başarılı: {username}")
                                        self.hide_loading()
                                        self.show_snackbar("Giriş başarılı! İnternet bağlantınız hazır.")
                                    else:
                                        logging.warning("Yeniden giriş başarısız oldu")
                                        self.hide_loading()
                                        self.show_snackbar("Yeniden giriş başarısız oldu! Lütfen tekrar deneyin.")
                                else:
                                    logging.warning("Oturum sonlandırma başarısız oldu")
                                    self.hide_loading()
                                    self.show_snackbar("Oturum sonlandırma başarısız oldu! Lütfen tekrar deneyin.")
                            else:
                                logging.warning("Oturum sonlandırma isteği başarısız")
                                self.hide_loading()
                                self.show_snackbar("Oturum sonlandırma isteği başarısız! Lütfen tekrar deneyin.")
                        else:
                            logging.warning("ViewState değeri bulunamadı")
                            self.hide_loading()
                            self.show_snackbar("ViewState değeri bulunamadı! Lütfen tekrar deneyin.")
                    else:
                        # Maksimum cihaz sayfasına erişilemiyorsa, doğrudan giriş yapmış demektir
                        logging.info("Maksimum cihaz sayfasına erişilemedi, doğrudan giriş yapıldı")
                        self.session = session
                        self.hide_loading()
                        self.show_snackbar("Giriş başarılı! İnternet bağlantınız hazır.")
                else:
                    logging.warning(f"Giriş başarısız: {username}")
                    self.hide_loading()
                    self.show_snackbar("Giriş başarısız! Kullanıcı adı veya şifre hatalı olabilir.")
            else:
                logging.warning(f"Giriş başarısız. Durum Kodu: {response.status_code}")
                self.hide_loading()
                self.show_snackbar(f"Giriş başarısız! Durum Kodu: {response.status_code}. Lütfen tekrar deneyin.")
                
        except requests.exceptions.Timeout:
            logging.error("Bağlantı zaman aşımına uğradı")
            error_message = "Sunucu yanıt vermiyor! İstek zaman aşımına uğradı."
            self.show_error_dialog("Bağlantı Hatası", error_message)
        except urllib3.exceptions.NameResolutionError as e:
            logging.error(f"DNS Çözümleme Hatası: {str(e)}")
            error_message = "GSB WiFi sunucusu bulunamadı!\n\n" \
                            "- Cihazınızın GSB WiFi ağına bağlı olduğundan emin olun\n" \
                            "- İnternet bağlantınızı kontrol edin\n" \
                            "- DNS sunucularınızı kontrol edin"
            self.show_error_dialog("DNS Çözümleme Hatası", error_message)
        except requests.exceptions.SSLError as e:
            logging.error(f"SSL Hatası: {str(e)}")
            error_message = "SSL bağlantı hatası! Lütfen internet bağlantınızı kontrol edin."
            self.show_error_dialog("SSL Hatası", error_message)
        except requests.exceptions.ConnectionError as e:
            logging.error(f"Bağlantı Hatası: {str(e)}")
            
            # Özel hata türüne göre mesaj belirle
            if "Failed to resolve" in str(e) or "getaddrinfo failed" in str(e):
                error_message = "GSB WiFi sunucusu bulunamadı!\n\n" \
                                "- Cihazınızın GSB WiFi ağına bağlı olduğundan emin olun\n" \
                                "- İnternet bağlantınızı kontrol edin\n" \
                                "- DNS ayarlarınızı kontrol edin"
                self.show_error_dialog("DNS Çözümleme Hatası", error_message)
            else:
                error_message = "Sunucuya bağlanılamadı! Lütfen internet bağlantınızı kontrol edin ve tekrar deneyin."
                self.show_error_dialog("Bağlantı Hatası", error_message)
        except Exception as e:
            logging.error(f"Giriş hatası: {str(e)}")
            error_message = f"Beklenmeyen bir hata oluştu:\n{str(e)}\nLütfen tekrar deneyin."
            self.show_error_dialog("Hata", error_message)

    def logout(self, *args):
        if not self.current_account:
            logging.warning("Hesap seçilmeden çıkış denemesi yapıldı")
            self.show_snackbar("Lütfen bir hesap seçin!")
            return
            
        account = self.store.get(self.current_account)
        username = account['username']
        password = account['password']
        
        logging.info(f"Çıkış denemesi başlatılıyor: {username}")
        # Yükleme ekranını göster
        self.show_loading("Oturum sonlandırılıyor...")
        
        try:
            # Oturum için bir session oluşturuyoruz
            session = requests.Session()
            session.verify = False  # SSL doğrulamasını devre dışı bırak
            
            # Headers ekle
            headers = {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36',
                'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
                'Accept-Language': 'tr,en-US;q=0.9,en;q=0.8',
                'Accept-Encoding': 'gzip, deflate, br',
                'Connection': 'keep-alive',
                'Upgrade-Insecure-Requests': '1'
            }
            session.headers.update(headers)
            
            # Giriş formunu doldurmak için gerekli veriler
            login_url = 'https://wifi.gsb.gov.tr/j_spring_security_check'
            login_data = {
                'j_username': username,
                'j_password': password,
                'submit': 'Giriş'
            }
            
            # Giriş isteği
            self.update_loading_message("Çıkış için önce giriş yapılıyor...")
            logging.info("Çıkış için önce giriş yapılıyor...")
            login_response = session.post(login_url, data=login_data)
            logging.info(f"Giriş yanıtı - Durum Kodu: {login_response.status_code}")
            
            # Giriş başarılı mı kontrol et
            if login_response.status_code == 200:
                if "j_spring_security_check" not in login_response.url:
                    self.update_loading_message("Giriş başarılı, oturum sonlandırılıyor...")
                    logging.info("Giriş başarılı, oturum sonlandırma işlemi devam ediyor...")
                    
                    # Maksimum cihaz sayfasına git
                    maksimum_cihaz_url = 'https://wifi.gsb.gov.tr/maksimumCihazHakkiDolu.html'
                    self.update_loading_message("Cihaz bağlantıları kontrol ediliyor...")
                    logging.info("Maksimum cihaz sayfasına erişiliyor...")
                    maksimum_cihaz_response = session.get(maksimum_cihaz_url)
                    logging.info(f"Maksimum cihaz sayfası yanıtı - Durum Kodu: {maksimum_cihaz_response.status_code}")
                    
                    if maksimum_cihaz_response.status_code == 200:
                        self.update_loading_message("Bağlantı bilgileri alınıyor...")
                        logging.info("Maksimum cihaz sayfası yüklendi, ViewState aranıyor...")
                        
                        # ViewState değerini bul
                        soup = BeautifulSoup(maksimum_cihaz_response.text, 'html.parser')
                        view_state_input = soup.find('input', {'name': 'javax.faces.ViewState'})
                        
                        if view_state_input:
                            view_state = view_state_input.get('value')
                            logging.info(f"ViewState bulundu: {view_state}")
                            
                            # Oturum sonlandırma isteği için headers
                            ajax_headers = {
                                'faces-request': 'partial/ajax',
                                'x-requested-with': 'XMLHttpRequest',
                                'content-type': 'application/x-www-form-urlencoded; charset=UTF-8',
                            }
                            session.headers.update(ajax_headers)
                            
                            # Sonlandırma isteği için form verileri
                            logout_data = {
                                'javax.faces.partial.ajax': 'true',
                                'javax.faces.source': 'j_idt20:0:j_idt28:j_idt29',
                                'javax.faces.partial.execute': '@all',
                                'javax.faces.partial.render': '@all',
                                'j_idt20:0:j_idt28:j_idt29': 'j_idt20:0:j_idt28:j_idt29',
                                'j_idt20:0:j_idt28': 'j_idt20:0:j_idt28',
                                'javax.faces.ViewState': view_state
                            }
                            
                            # Oturum sonlandırma isteği
                            self.update_loading_message("Oturum sonlandırma isteği gönderiliyor...")
                            logging.info("Oturum sonlandırma isteği gönderiliyor...")
                            logout_response = session.post(
                                maksimum_cihaz_url,
                                data=logout_data
                            )
                            logging.info(f"Oturum sonlandırma yanıtı - Durum Kodu: {logout_response.status_code}")
                            
                            if logout_response.status_code == 200:
                                self.update_loading_message("Oturum sonlandırıldı, son işlemler yapılıyor...")
                                logging.info("Oturum sonlandırma isteği başarılı, 2 saniye bekleniyor...")
                                time.sleep(2)
                                
                                # Çıkış URL'sine yönlendir
                                final_logout = session.get('https://wifi.gsb.gov.tr/logout')
                                logging.info(f"Final çıkış yanıtı - Durum Kodu: {final_logout.status_code}")
                                
                                if final_logout.status_code in [302, 200]:
                                    self.session = None  # Session'ı sıfırla
                                    logging.info("Oturum başarıyla sonlandırıldı")
                                    self.hide_loading()
                                    self.show_snackbar("Oturum başarıyla sonlandırıldı! WiFi bağlantınız kesildi.")
                                else:
                                    logging.warning("Final çıkış başarısız")
                                    self.hide_loading()
                                    self.show_snackbar("Çıkış başarısız! Lütfen tekrar deneyin.")
                            else:
                                logging.warning("Oturum sonlandırma isteği başarısız")
                                self.hide_loading()
                                self.show_snackbar("Oturum sonlandırma isteği başarısız! Lütfen tekrar deneyin.")
                        else:
                            logging.warning("ViewState değeri bulunamadı")
                            self.hide_loading()
                            self.show_snackbar("ViewState değeri bulunamadı! Lütfen tekrar deneyin.")
                    else:
                        logging.warning("Maksimum cihaz sayfasına erişilemedi")
                        self.hide_loading()
                        self.show_snackbar("Maksimum cihaz sayfasına erişilemedi! WiFi sisteminde bir sorun olabilir.")
                else:
                    logging.warning("Giriş başarısız, çıkış yapılamıyor")
                    self.hide_loading()
                    self.show_snackbar("Çıkış başarısız! Kullanıcı adı veya şifre hatalı olabilir.")
            else:
                logging.warning(f"Giriş başarısız. Durum Kodu: {login_response.status_code}")
                self.hide_loading()
                self.show_snackbar(f"Çıkış başarısız! Durum Kodu: {login_response.status_code}. Lütfen tekrar deneyin.")
                
        except requests.exceptions.Timeout:
            logging.error("Bağlantı zaman aşımına uğradı")
            error_message = "Sunucu yanıt vermiyor! İstek zaman aşımına uğradı."
            self.show_error_dialog("Bağlantı Hatası", error_message)
        except urllib3.exceptions.NameResolutionError as e:
            logging.error(f"DNS Çözümleme Hatası: {str(e)}")
            error_message = "GSB WiFi sunucusu bulunamadı!\n\n" \
                            "- Cihazınızın GSB WiFi ağına bağlı olduğundan emin olun\n" \
                            "- İnternet bağlantınızı kontrol edin\n" \
                            "- DNS sunucularınızı kontrol edin"
            self.show_error_dialog("DNS Çözümleme Hatası", error_message)
        except requests.exceptions.SSLError as e:
            logging.error(f"SSL Hatası: {str(e)}")
            error_message = "SSL bağlantı hatası! Lütfen internet bağlantınızı kontrol edin."
            self.show_error_dialog("SSL Hatası", error_message)
        except requests.exceptions.ConnectionError as e:
            logging.error(f"Bağlantı Hatası: {str(e)}")
            
            # Özel hata türüne göre mesaj belirle
            if "Failed to resolve" in str(e) or "getaddrinfo failed" in str(e):
                error_message = "GSB WiFi sunucusu bulunamadı!\n\n" \
                                "- Cihazınızın GSB WiFi ağına bağlı olduğundan emin olun\n" \
                                "- İnternet bağlantınızı kontrol edin\n" \
                                "- DNS ayarlarınızı kontrol edin"
                self.show_error_dialog("DNS Çözümleme Hatası", error_message)
            else:
                error_message = "Sunucuya bağlanılamadı! Lütfen internet bağlantınızı kontrol edin ve tekrar deneyin."
                self.show_error_dialog("Bağlantı Hatası", error_message)
        except Exception as e:
            logging.error(f"Çıkış hatası: {str(e)}")
            error_message = f"Beklenmeyen bir hata oluştu:\n{str(e)}\nLütfen tekrar deneyin."
            self.show_error_dialog("Hata", error_message)

    def show_snackbar(self, text):
        try:
            # KivyMD 2.0+ için
            from kivymd.uix.snackbar import MDSnackbar
            from kivymd.uix.label import MDLabel
            
            # Label oluştur
            snackbar_label = MDLabel(
                text=text,
                theme_text_color="Custom",
                text_color=(1, 1, 1, 1)
            )
            
            # Snackbar oluştur
            snackbar = MDSnackbar(
                pos_hint={"center_x": 0.5, "center_y": 0.1},
                size_hint_x=0.9,
                duration=3
            )
            
            # Label'ı snackbar'a ekle
            snackbar.add_widget(snackbar_label)
            snackbar.open()
            
        except Exception as e:
            # Eski sürüm veya başka hata durumunda direkt print kullan
            logging.error(f"Snackbar hatası: {str(e)}")
            # Konsola yazdır
            print(f"Mesaj: {text}")

if __name__ == '__main__':
    from kivy.config import Config
    Config.set('kivy', 'exit_on_escape', '0')
    OturumuYonetici().run() 