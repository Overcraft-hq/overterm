# Docker — analiz

Overterm'e Docker Desktop'ın yapabildiklerinin neredeyse tamamı, daha iyi bir
arayüzle ve kısayollarla:
- konteynerler, compose projeleri,
- imajlar, volume'lar, ağlar,
- build'ler, zafiyetler, yerel modeller,
- motorun kendisi.

Asıl şart geliştirici dostu olması.

Bu belge şunları toplar:
- kodun bugünkü hali,
- bu Mac'te Docker'la ölçtüklerimiz,
- Docker Desktop'ın özellik envanteri ve her birini nasıl yapacağımız,
- arayüzün ve kısayolların tasarımı,
- aşamalar ve verilmesi gereken kararlar.

Uygulama planı kararlardan sonra.

Satır numaraları 2026-10-27'deki `main`'e göre (`3a5aee1`).

## Kısaca

- **Docker Desktop'ın hemen hepsini verebiliriz.** Arayüzde yaptığı hemen her
  şeyin bir Engine API uç noktası ya da bir CLI karşılığı var:
  - **Engine API:** konteynerler, imajlar, volume'lar, ağlar, olaylar,
    loglar, istatistikler; konteynerin içindeki dosyalar bile.
  - **Docker Desktop'ın CLI eklentileri:** motoru başlatma, durdurma ve
    güncelleme (`docker desktop`), build kayıtları (`docker buildx history`),
    zafiyetler (`docker scout`), yerel modeller (`docker model`).

  Bilerek dışarıda bıraktıklarımız Bölüm 3'te: eklenti mağazası (CLAUDE.md:
  eklenti yuvası yok), Docker Desktop'ın kendi kaynak ayarları (dışarıya
  açık bir API'leri yok), Kubernetes arayüzü.
- **Docker'la iki yoldan konuşalım.**
  - **Engine API, unix socket üzerinden:** okuma, canlı akışlar ve tekil
    eylemler. Hızlı (30–230 ms), yapılandırılmış ve polling gerektirmiyor.
  - **Terminal tab'ına yazılan komutlar:** compose, `exec`, build ve kayıt
    defteriyle ilgili işlemler. Geliştirici ne çalıştığını görür ve
    kopyalayabilir.

  SwiftNIO zaten bağımlılık, yeni paket gerekmiyor.
- **Arayüz iki katmanlı, aynı model üzerinde.**
  - **Docker sayfası (⌥⌘P):** Settings ve Notes gibi gövdeyi kaplıyor.
    Docker Desktop'ın panosunun tamamı burada: bölümler, liste, ayrıntı.
  - **Rail'deki Docker paneli:** Terminalin yanında "bu checkout'un
    stack'i". Loglar sağ slotta, terminalden ayrılmadan görünüyor.
- **Daha iyi olan taraf klavye ve bağlam.**
  - Her şey klavyeyle yapılabiliyor: liste odaktayken tek harf eylemler, `/`
    ile süzme, ⇧⌥⌘P ile her şeye atlayan bir geçiş penceresi, ⌘K paleti.
  - Docker Desktop'ın yapamadığı bağlantılar:
    - checkout'a ve worktree'ye göre kapsam,
    - konteyner portları panel başlığında (bugün görünmüyor),
    - konteynerin içindeki dosyayı Overterm'in editöründe düzenleme,
    - DB konteynerinden Database client bağlantısı,
    - ölen konteyneri tab'da "seni bekliyor" olarak işaretleme,
    - ajanlar için MCP araçları.

## 1. Bu Mac'te doğrulananlar (2026-10-27)

| Ne | Sonuç |
|---|---|
| Çalışma ortamı | Docker Desktop 4.95, Engine 29.8.2, API 1.56 (sunucunun en düşüğü 1.40), `arm64`; `docker desktop status` → running |
| Context | `desktop-linux` → `unix:///Users/…/.docker/run/docker.sock`; `/var/run/docker.sock` ona symlink; `~/.docker/config.json`'da `currentContext`; kaydı `~/.docker/contexts/meta/<sha256("desktop-linux")>/meta.json` (doğrulandı) |
| Hız (socket, `curl`) | `containers/json?all=1` 54 ms; `inspect`, tek seferlik `stats`, `logs?tail=5` ~30 ms; `/volumes` 34 ms, `/networks` 35 ms, `/images/json` 228 ms (43 KB), imaj geçmişi 47 ms |
| Loglar | TTY'siz konteynerde 8 byte'lık çoklama çerçeveleri (`02` = stderr, ardından uzunluk); ayrıştırmamız gerekiyor |
| Olaylar | `/events?filters={"type":["container"]}` açık kalan bir akış; olay yokken bir şey göndermiyor |
| Dosyalar | `HEAD /containers/<id>/archive?path=/etc/hostname` → 200 ve `X-Docker-Container-Path-Stat` (base64 JSON: ad, boyut, mod, mtime). Konteynerde shell olmadan dosya gezinmek mümkün |
| Disk | `system/df`: 69 imaj, 70 volume, 387 build cache girdisi |
| **Portlar** | Konteynerin yayımladığı 55432'yi `com.docker.backend` dinliyor (`lsof`). Hiçbir tab'ın süreç ağacında değil, yani Overterm'in port göstergesi `docker compose up` çalışan bir tab'ın portlarını **bugün göremiyor** |
| CLI eklentileri | `~/.docker/cli-plugins`: agent, ai, buildx (0.37.2), compose (5.6.0), debug, desktop (4.95.0), dhi, extension, init, mcp (0.44.1), model, offload, pass, sandbox, scout |
| Makine okur çıktılar | `docker buildx history ls --format json` (doğrulandı, adım ve önbellek sayılarıyla); `docker model list --json`; `docker scout cves --format sarif\|spdx`; `docker desktop status --format` |
| Kararsızlık | `docker mcp server ls` "obsolete, see `docker mcp profile server ls`" diyor: MCP Toolkit'in CLI'ı hızlı değişiyor |
| Dikkat | `docker debug version` bir imaj çekmeye başladı (yarıda kaldı, bir şey bırakmadı). Bazı eklentiler yan etkili; Overterm onları yalnızca kullanıcının istediği bir eylemle çalıştırmalı |
| Editör | `Dockerfile`/`Containerfile` ve YAML grameri zaten var (`Syntax/EditorLanguage.swift:103`, `:161`, `:177`) |
| Compose | Bu Mac'te şu an çalışan bir compose projesi yok (iki tekil konteyner: `cg-test-pg`, `cg-moto`). Etiketlere göre gruplama belgeden biliniyor, burada denenmedi |

## 2. Kodun bugünkü durumu

Docker'a dokunan bir şey yok. Bağlanacağı yerler:

| Parça | Nerede | Docker için anlamı |
|---|---|---|
| Gövdeyi kaplayan sayfalar | `WorkspaceOverlay` (Settings, Notes) | Docker sayfası üçüncü bir sayfa |
| Rail panelleri | `SidebarPanel` (`Sidebar/SidebarView.swift:66`): files, git, sessions, snippets, api, notes, database | Yeni bir `docker` paneli; ayarla açılıp kapanır |
| Sağ slot | `RightPaneView` modları (`Diff/RightPaneView.swift:7`) | Konteynerin logları ve ayrıntısı için bir mod; yalnızca görünürken okur |
| Database client | `Database/`; `DatabaseMCP.allow` (`:113`) yazmaları kullanıcıya soruyor | Kalıp aynı (model, panel, sağ slot, MCP); DB konteynerinden bağlantıya geçiş |
| Portlar | `Info/ListeningPorts.swift:17` (`lsof`, tab'ın süreçleri) | Docker'ın portları buraya eklenmeli |
| Tab türü | `TabKind` (`Tabs/TabKind.swift:13`) | `docker exec` tab'ı için `container` türü |
| Tarayıcı | `openInBrowser(_:for:)` (`Window/TerminalWindowController+Browser.swift:165`) | Web portu tab'ın tarayıcısında |
| Yeni tab'da komut | `newTab(in:running:)` (`Window/TerminalWindowController.swift:1048`) | compose, `exec`, `logs -f`, build, pull/push buradan |
| Editör | `EditorViewController`; `ExternalOpener` | Konteynerdeki bir dosyayı açıp geri yazmak; `daemon.json` |
| Seçiciler | `EditorPicker`, ⌘K paleti (`PaletteModel`), `FuzzyMatch` | Docker geçiş penceresi ve palet girdileri |
| Kısayollar | `KeyCommands` (yeniden atanabilir, Settings ▸ Keyboard Shortcuts) | Docker'ın genel kısayolları burada; liste içi tek harfler değil |
| MCP | `BrowserMCP.handle` önek dalları (`Browser/BrowserMCP.swift:60`, `:72`) | `docker_` önekli bir grup |
| Dikkat | `AttentionNotifier`, `TabActivity` | Çıkan ya da sağlıksız konteyner → tab işareti, bildirim |
| SSH tüneli | `Database/SSHTunnel` | Uzak bir Docker context'inin socket'ini iletmek |
| Test sunucuları | `Scripts/database-test-servers.sh` | Database testleri zaten Docker'da; Docker bu projede bir geliştirme aracı |
| Bağımlılıklar | `Package.swift:18` swift-nio | Unix socket'te HTTP için `NIOHTTP1`; yeni paket yok |

## 3. Docker Desktop'ın envanteri ve karşılıkları

Docker Desktop 4.x'in panosu ve ayarları, bölüm bölüm. "Nasıl" sütunu: **API**
Engine API (socket), **CLI** bir komut (arka planda, JSON okunarak), **Tab** bir
terminal tab'ına yazılan komut, **Yardımcı** kısa ömürlü bir yardımcı konteyner.

### Konteynerler

| Docker Desktop | Bizde | Nasıl | Aşama |
|---|---|---|---|
| Liste, compose'a göre gruplu; arama, "yalnızca çalışanlar" | Aynısı; checkout'unki üstte; sütunlarda CPU ve bellek | API (`containers/json`, `events`) | 1 |
| Start, stop, restart, pause, resume, kill, delete; toplu seçim | Aynısı, tek harflerle ve toplu | API | 1 |
| Port bağlantıları, tarayıcıda aç | Tab'ın tarayıcı sütununda; panel başlığında | API | 1 |
| Logs (arama, kopyalama) | Takip, arama ve regex, seviye renkleri, JSON loglar okunur halde, stderr işareti, zaman aralığı, bir compose projesinin birleşik logları; seçili satırları ⌘L ile ajana | API (`logs`, çerçeveler) | 1 |
| Inspect | JSON ağacı ve okunur özet; env'de sırlar maskeli | API | 1 |
| Bind mount'lar | Liste; host yolunu Finder'da ya da Overterm'in Files panelinde açma | API | 1 |
| Exec (gömülü terminal) | Yeni bir Overterm tab'ı: `docker exec -it <c> sh` (bash varsa bash), tab türü `container` | Tab | 1 |
| Files (gez, düzenle, içe/dışa aktar, sil) | Gez; dosyayı Overterm'in editöründe aç ve geri yaz; sürükle bırak ile içe/dışa aktar | API (`archive` GET/PUT/HEAD) | 1 |
| Stats (CPU, bellek, disk, ağ grafikleri) | Aynısı; yalnızca görünürken akar | API (`stats?stream=1`) | 1 |
| Run (ayarlarla) | Sayfada "Run" penceresi: ad, portlar, volume'lar, env, ağ, yeniden başlatma; "Copy as `docker run`" | API (`create`, `start`) | 2 |
| `top`, değişen dosyalar, dışa aktar | Süreçler, `diff`; dosya sistemini tar olarak dışa aktar | API (`top`, `changes`, `export`) | 2 |
| Docker Debug (shell'siz konteynerde shell; Pro aboneliği) | Konteynerin ad alanlarını paylaşan bir busybox ile shell; abonelik gerekmez | Tab (`docker run --pid/--network container:<c>`) | 2 |

### Compose

| Docker Desktop | Bizde | Nasıl | Aşama |
|---|---|---|---|
| Proje grubu; proje düzeyinde start, stop, delete | up -d, down (`-v` sorarak), restart, pull, build, servis bazında; checkout'a göre | Tab | 1 |
| — | Projenin çözülmüş modeli: servisler, portlar, `depends_on` grafiği, env | CLI (`docker compose config --format json`) | 2 |
| — | Compose dosyası editörde: servis satırında ▶ (up), `config` hataları teşhis olarak | CLI ve editör | 2 |
| — | Worktree çakışmaları: aynı host portunu isteyen iki stack, çözüm önerisi | API ve `lsof` | 2 |

### İmajlar

| Docker Desktop | Bizde | Nasıl | Aşama |
|---|---|---|---|
| Liste (boyut, oluşturma, kullanımda); süzme | Aynısı; kullanılmayanlar ve dangling işaretli | API (`images/json`) | 2 |
| Inspect, katmanlar | Katmanlar boyut çubuklarıyla, her katmanı yaratan komut | API (`history`, `json`) | 2 |
| Pull, push, tag, delete, prune | Pull (genel imajlar ilerleme çubuğuyla), tag, delete, prune (önizlemeli); push ve özel imajlar terminalde | API ve Tab | 2 |
| Run | Konteynerlerdeki "Run" penceresi, imajın `EXPOSE` ve `VOLUME`'larından önceden dolu | API | 2 |
| Hub'da arama, depolar | Hub'da arama ve etiketler | API (`images/search`), Hub'ın genel API'si | 3 |
| Docker Scout (CVE'ler, öneriler) | İmajın CVE özeti ve listesi, temel imaj önerileri | CLI (`scout quickview`, `cves --format sarif`, `recommendations`) | 3 |

### Volume'lar ve ağlar

| Docker Desktop | Bizde | Nasıl | Aşama |
|---|---|---|---|
| Volume listesi (boyut, kullanımda), oluştur, sil | Aynısı; kullanan konteynerler; prune (önizlemeli) | API (`volumes`, `system/df`) | 2 |
| Volume'un verisini gezme | Gezme ve dosyayı editörde açma (salt okuma) | Yardımcı (volume'u salt okunur bağlayan küçük bir konteyner) ve `archive` | 2 |
| Dışa/içe aktarma, klonlama, boşaltma | tar olarak dışa/içe aktar, klonla | Yardımcı | 3 |
| Ağlar (Docker Desktop'ta öne çıkan bir görünüm değil) | Liste, inspect, bağlı konteynerler, oluştur, sil, prune | API (`networks`) | 2 |

### Build'ler

| Docker Desktop | Bizde | Nasıl | Aşama |
|---|---|---|---|
| Build geçmişi (durum, süre, önbellek) | Aynısı; checkout'a göre süzme | CLI (`buildx history ls --format json`) | 3 |
| Build ayrıntısı: zamanlama, loglar, hatalar, Dockerfile | Loglar; hata satırından Dockerfile'daki satıra gitme | CLI (`history inspect`, `logs`) ve editör | 3 |
| Builder'lar, build önbelleği | Liste; önbelleği temizleme | CLI (`buildx ls`), API (`build/prune`) | 3 |
| Build başlatma | `docker build`/`compose build` terminalde | Tab | 1 |

### Motor ve ayarlar

| Docker Desktop | Bizde | Nasıl | Aşama |
|---|---|---|---|
| Motorun durumu; başlat, durdur, yeniden başlat | Durum çubuğu; Docker Desktop'ı başlat, durdur, yeniden başlat | CLI (`docker desktop status/start/stop/restart`); OrbStack ve Colima için kendi komutları | 1 |
| Context'ler | Seçici; yalnızca Overterm için seçmek ya da `docker context use` ile varsayılan yapmak | Dosyalar ve CLI | 1 |
| Disk kullanımı, temizlik | `system df`; imaj, volume, önbellek için önizlemeli prune | API | 2 |
| Docker Engine ayarı (`daemon.json` düzenleyici) | `~/.docker/daemon.json` Overterm'in editöründe; JSON doğrulama; kaydedince "Yeniden başlat" | Editör ve CLI | 2 |
| Güncellemeler, tanılama | Güncelleme var mı, güncelle; tanılama paketi | CLI (`docker desktop update`, `diagnose`) | 3 |
| Kaynaklar (CPU, bellek, disk sınırı), dosya paylaşımı, proxy | **Yok**: Docker Desktop'ın kendi ayarları, dışarıya API'si yok; "Docker Desktop'ta aç" bağlantısı | — | — |
| Kubernetes | Durum ve aç/kapat; bir Kubernetes arayüzü **yok** | CLI (`docker desktop kubernetes`) | 3 |

### Docker Desktop'ın diğerleri

| Docker Desktop | Bizde | Neden |
|---|---|---|
| Model Runner (yerel LLM'ler) | Liste, çekme, çalıştırma (terminalde sohbet), loglar, disk | CLI (`docker model … --json`); 3. aşama |
| MCP Toolkit (MCP sunucuları kataloğu) | Liste ve aç/kapat; 3. aşama | CLI'ı kararsız (Bölüm 1); Overterm'in ajanları zaten kendi MCP'sini alıyor |
| Eklenti mağazası | **Yok** | CLAUDE.md: eklenti yuvası yok |
| Ask Gordon (Docker AI) | **Yok** | Overterm'in ajanları aynı işi, kendi MCP araçlarıyla yapıyor |
| Hesap, Docker Hub girişi | Terminalde `docker login` | Kimlik bilgileri Docker'ın credential helper'ında kalsın |
| Offload, Hardened Images, Sandboxes | **Yok** (şimdilik) | Abonelik ya da hesap gerektiren, hızla değişen ürünler |

## 4. Docker'la nasıl konuşacağız

### Seçenekler

| | `docker` CLI (`--format json`) | Engine API (unix socket) | Bir SDK |
|---|---|---|---|
| Kurulum | `docker` ikilisinin PATH'te olması; GUI uygulamasının PATH'i dar (`/usr/local/bin`, `/opt/homebrew/bin`, `~/.docker/bin`, `~/.orbstack/bin` aranmalı) | Yalnızca socket'in yolu | Swift için resmi SDK yok |
| Hız | Her çağrı bir süreç (~100 ms+) | 30–230 ms, süreç yok | — |
| Canlılık | `docker events` uzun ömürlü bir süreç | `/events` akışı; polling yok | — |
| Compose ve eklentiler | Var | **Yok**: compose istemci tarafında; Scout, Model, Desktop birer eklenti | — |
| Biçim | CLI sürümüne göre değişen metin/JSON | Sürümlü, belgelenmiş JSON | — |

**Önerim melez.**
- **API:** Konteyner, imaj, volume ve ağ işleri, olaylar, loglar,
  istatistikler, dosyalar.
- **Arka planda CLI:** Yalnızca JSON veren eklentiler (build geçmişi, Scout,
  Model, `docker desktop status`), bir GCD iş parçacığında (`Git.run` gibi).
- **Terminal tab'ı:** Kullanıcının görmesi gereken, uzun süren ya da kimlik
  isteyen her şey: compose, `exec`, build, push, özel imaj çekme, `docker
  login`. Geliştirici ne çalıştığını görür ve kopyalayabilir. Ghostty
  ilerleme çubuklarını ve renkleri çizer, ⌘F ve komut blokları
  kendiliğinden gelir, işlem ⌃C ile kesilir.

### Socket'i bulmak

Docker CLI'ın sırası, aynen:
1. `DOCKER_HOST`.
2. `DOCKER_CONTEXT`.
3. `~/.docker/config.json`'daki `currentContext`.
4. O context'in kaydı (`meta.json`, `Endpoints.docker.Host`).
5. Varsayılan `unix:///var/run/docker.sock`.

Saf bir fonksiyon, birim testli.

| Ortam | Socket | Context | Eklentiler |
|---|---|---|---|
| Docker Desktop | `~/.docker/run/docker.sock` | `desktop-linux` | Hepsi |
| OrbStack | `~/.orbstack/run/docker.sock` | `orbstack` | buildx, compose; `desktop` yok, diğerleri kuruluma göre |
| Colima | `~/.colima/<profil>/docker.sock` | `colima` | Homebrew'dan ne kurulduysa |
| Rancher Desktop | `~/.rd/docker.sock` | `rancher-desktop` | Kendi paketlediği |
| Podman | `podman machine`'in socket'i (Docker uyumlu API) | — | — |

Docker Desktop dışındakiler bu Mac'te denenmedi; yollar belgelerinden. Özellikler eklentinin varlığına ve `/info`'ya göre açılır. Örneğin Model
Runner bölümü yalnızca `docker model` varsa görünür. `ssh://` ve `tcp://`
context'leri (uzak makineler) 3. aşamada: Database'in `SSHTunnel`'ı uzak
socket'i iletebilir (`ssh -L yerel.sock:/var/run/docker.sock`).

### Ayrıntılar

- **Sürüm:** `/_ping`'in `API-Version` başlığı; isteklerde sunucunun ve
  bizim desteklediğimizin küçüğü.
- **Akışlar:** `events`, `logs?follow=1`, `stats?stream=1` ve pull'un
  ilerlemesi chunked JSON. NIOHTTP1 bunları çözüyor; log çerçevelerini
  biz ayırıyoruz (saf, testli).
- **Docker kapalıyken:** Panel ve sayfa bunu söyler, "Başlat" önerir
  (`docker desktop start` ya da ortamın komutu). Geri gelince ölçülü
  aralıklarla yeniden bağlanır; kapalıyken CPU harcamaz.
- **Compose etiketleri:**
  - `com.docker.compose.project`
  - `com.docker.compose.project.working_dir`
  - `com.docker.compose.project.config_files`
  - `com.docker.compose.service`
  - `com.docker.compose.container-number`
  - `com.docker.compose.oneoff`
  - `com.docker.compose.depends_on`

  Proje ve servis ağacı bunlardan kurulur, CLI'a sormadan.
- **Konteynerdeki dosyalar:** `archive` uç noktası tar konuşuyor; bir
  dosyayı açmak tek girdili bir tar'ı açmak, geri yazmak tek girdili bir
  tar'ı PUT etmek (saf bir tar okuyucu/yazıcı, testli). Konteyner durmuş
  olsa da çalışır.
- **Yardımcı konteynerler** (volume gezme, dışa aktarma): imaj olarak
  makinede zaten olan küçük bir imaj ya da bir kez çekilen `busybox`.
  Çekmeden önce kullanıcıya söylenir. Bir etiketle işaretlenir ve işi
  bitince silinir.
- **Kimlik bilgileri:** Overterm hiçbir kayıt defteri şifresini görmez.
  Kimlik isteyen işler terminalde, Docker'ın credential helper'ıyla yapılır.

## 5. Arayüz

### İki katman

| Katman | Ne zaman | Ne var |
|---|---|---|
| **Docker sayfası** (⌥⌘P) | Yönetmek: temizlik, imajlar, volume'lar, build'ler, motor | Gövdeyi kaplayan sayfa (`WorkspaceOverlay`), Settings ve Notes gibi. Solda bölümler (Konteynerler, İmajlar, Volume'lar, Ağlar, Build'ler, Modeller, Motor), ortada liste, sağda ayrıntı (Logs, Inspect, Files, Stats, Mounts). Altta motor çubuğu: context, durum, toplam CPU ve bellek, disk, güncelleme |
| **Docker paneli** (rail) | Çalışırken: "bu dalın veritabanı ayakta mı, logu ne diyor" | Seçili tab'ın checkout'unun stack'i en üstte, altında diğerleri. Bir konteyner seçilince logları sağ slotta, terminalin yanında. Aynı tek harf eylemler |

İkisi aynı modeli (`DockerModel`: bağlantı, olay akışı, konteyner ve proje
ağacı) paylaşır. Sayfa ya da panel görünmüyorsa liste ve olaylar yine akar
(port göstergesi ve dikkat işaretleri için tek bir bağlantı). İstatistikler,
loglar ve imaj listesi yalnızca görünürken okunur (CLAUDE.md: görünmeyen
panel okumaz).

Terminal tab'ları üçüncü yer: `exec`, `logs -f`, compose ve build
çıktıları. Docker Desktop'ın gömülü terminalinin yerine Overterm'in kendi
tab'ları; split, arama, komut blokları, ajana sorma dahil.

### Docker Desktop'tan daha iyi olacak yerler

1. **Klavye önce.** Fare gerekmiyor (Bölüm 6). Docker Desktop'ta bir
   konteynerin logu üç tıklama; burada ⇧⌥⌘P ve adın birkaç harfi, sonra ↩.
2. **Bağlam.**
   - Liste, çalıştığın checkout'un stack'iyle başlıyor.
   - Portlar terminalin panel başlığında.
   - Ölen bir konteyner, onu başlatan tab'ı işaretliyor.
3. **Şeffaf.** Her eylem çalıştırdığı komutu söylüyor ("Copy as Command");
   uzun işler terminalde.
4. **Okunur loglar.** JSON log satırları açılır, seviyeler renkli. Bir
   compose projesinin servisleri tek akışta, servis adıyla renkli. Hata
   satırına atla. Seçili satırlar ⌘L ile ajana.
5. **Editör bir tık ötede.**
   - Konteynerdeki bir dosya, compose dosyası, Dockerfile ve `daemon.json`
     Overterm'in editöründe, sözdizimi renkleriyle.
   - Konteyner dosyası kaydedilince konteynere geri yazılıyor.
6. **Güvenli temizlik.** Prune silinecekleri listeliyor, toplam boyutla;
   kullanımda olan dokunulmaz. `down -v` volume'ları adlarıyla soruyor.
7. **Hatada yardım.**
   - "Port is already allocated" hatasında portu kimin tuttuğunu
     söylüyor: hangi worktree'nin stack'i, hangi tab, hangi süreç.
   - Çıkan konteynerin son satırları ve çıkış kodu listede.
8. **Hızlı.** Olaylarla canlı; liste 50 ms'de. Docker Desktop'ın Electron
   arayüzü değil, AppKit ve SwiftUI.

## 6. Kısayollar

İki tür kısayol var:
- **Genel olanlar:** `KeyCommands`'da (yeniden atanabilir, Settings ▸
  Keyboard Shortcuts'ta görünür).
- **Liste içi tek harfler:** Yalnızca Docker listesi odaktayken. Terminalde
  ya da editörde değil, oraya hiçbir tuş sızmaz.

### Genel (önerilen)

| Kısayol | Komut | Durum |
|---|---|---|
| ⌥⌘P | Docker sayfası, aç/kapat | Boş (KeyCommands'da da, Ghostty'nin `super+alt` tuşlarında da yok) |
| ⇧⌥⌘P | Docker'a geç: konteyner, servis, imaj, volume adıyla | Boş (⇧⌥⌘ ile hiçbir kısayol yok) |
| — | Compose Up / Down / Restart (bu checkout) | Palet ve menü; kısayol ataması kullanıcıya |
| ⌘K | Palette Docker girdileri: "Restart api", "Logs db", "Shell into web" | Var olan palet |

Geçiş penceresinde (⇧⌥⌘P) ↩ logları açar, ⌘↩ shell açar, ⌥↩ yeniden başlatır,
⌘O portu tarayıcıda açar.

### Liste odaktayken

| Tuş | Eylem |
|---|---|
| ↑ ↓, ← → | Gezinme; projeyi aç/kapa |
| ↩ | Ayrıntı (loglar) |
| Space | Hızlı bakış (Finder'ın Quick Look'u gibi): durum, portlar, son log satırları |
| `s` | Başlat / durdur |
| `r` | Yeniden başlat |
| `p` | Duraklat / sürdür |
| `l` | Loglar |
| `t` | Loglar terminalde (`docker logs -f`) |
| `e` | Shell (yeni tab'da `exec`) |
| `f` | Dosyalar |
| `i` | Inspect |
| `o` | Portu tarayıcıda aç |
| `d` | Database client'ta bağlan (DB konteynerleri) |
| `u` / `D` | Compose up / down (proje ya da servis üzerinde) |
| ⌫ | Sil (sorarak; toplu seçimde hepsini listeler) |
| ⌘A, ⇧↑/↓ | Toplu seçim |
| `/` | Süz: metin, ya da `status:running`, `project:api`, `image:postgres`, `port:5432` |
| `?` | Bu tablonun kendisi, bir kopya kağıdı olarak |
| ⌘C | Adı kopyala; ⌥⌘C kimliği |

Tuşlar lazydocker'ın ve VS Code'un alışkanlıklarına yakın. Sayfa ve panel
aynı tuşları kullanır. Sayfanın bölümleri arasında ⌃1…⌃7 (yalnızca sayfa
görünürken; ⌘1–9 tab'ların).

## 7. Overterm'e özgü taraf

### Worktree'ler ve compose

Compose'un proje adı varsayılan olarak compose dosyasının klasörünün adı.
Overterm'in worktree'leri (`repo-wt-feat-x`) farklı klasörler olduğu için
farklı projeler olur; buna kadar iyi. Ama compose dosyasındaki sabit host
portları (`5432:5432`) ikinci worktree'nin stack'inde "port is already
allocated" ile düşer.

Sayfa ve panel portu hangi projenin, hangi worktree'nin ve hangi tab'ın
tuttuğunu söyler. İlk etapta öbür stack'i durdurmayı önerir; 2. aşamada
worktree başına bir port kaydırması ya da `COMPOSE_PROJECT_NAME`.
New Task, bir seçenekle worktree'nin stack'ini de başlatabilir (2. aşama).

### Portlar

Konteyner portları `com.docker.backend` adına dinlendiği için, `docker
compose up` çalışan tab'ın panel başlığı bugün boş. Model, bir projenin
portlarını, `working_dir`'i tab'ın checkout'u olan tab'a verir. Böylece panel
başlığındaki port göstergesi, "Aç" ve tarayıcı sütunu Docker için de çalışır;
kaynağı belli olacak şekilde, bir konteyner ikonuyla.

### Database client

`postgres`, `pgvector`, `mysql`, `mariadb`, `clickhouse`, `redis` gibi
imajlar tanınır. Konteynerin env'i (`POSTGRES_USER`, `POSTGRES_PASSWORD`,
`POSTGRES_DB`, `MYSQL_ROOT_PASSWORD`…) ve yayımlanan portu bir Database
bağlantısını önceden doldurur; şifre keychain'e gider. Bu Mac'teki
`cg-test-pg` (pgvector, 55432) birebir bu durum.

### Ajanlar

Ajanın zaten bir kabuğu var ve `docker` CLI'ını çalıştırabilir. MCP'nin
katkısı bu yüzden üç şey olmalı:
1. **Kapsam:** Tab'ın checkout'unun stack'i araçlara kendiliğinden geliyor.
2. **Yapı:** Loglar grep'lenmiş, kısaltılmış, sırları maskelenmiş geliyor.
3. **Onay:** restart, up/down ve rm pencerede kullanıcıya soruluyor
   (`DatabaseMCP.allow` gibi).

Araçlar:
- `docker_ps`
- `docker_logs` (tail, since, grep)
- `docker_inspect`
- `docker_stats`
- `docker_files` (okuma)
- `docker_restart`, `docker_compose_up`, `docker_compose_down` (onaylı)

### Dikkat

Bir konteyner sıfır olmayan bir kodla çıkarsa ya da `unhealthy` olursa, onu
başlatan tab'da işaret ve (ayarlıysa) bildirim çıkar.

## 8. Aşamalar

Docker Desktop'ın hemen hepsi hedef ama hepsi bir sürümde değil. Her aşama
kendi başına kullanılabilir.

| Aşama | Kapsam | Büyüklük |
|---|---|---|
| **1. Konteynerler ve compose** (günlük iş) | Bağlantı, context, motor durumu ve başlatma. Konteynerler: liste, eylemler, loglar, inspect, mount'lar, dosyalar (editörde düzenleme dahil), istatistikler, `exec` tab'ı, portlar (panel başlığı, tarayıcı). Compose: proje ağacı, eylemler terminalde, birleşik loglar. Sayfa ve panel, geçiş penceresi, tek harf tuşlar, palet. Dikkat işaretleri, Database'e geçiş, MCP (okuma ve onaylı eylemler). Build terminalde | Büyük; Database client kadar |
| **2. Yönetim** | İmajlar (liste, katmanlar, pull, tag, delete, prune, Run penceresi), volume'lar (liste, gezme, prune), ağlar, disk ve önizlemeli temizlik, `daemon.json` düzenleyici, compose'un çözülmüş modeli ve editörde compose, worktree çakışmaları, Docker Debug karşılığı, `top`/`changes`/`export`, Tab Info, API client'ın OpenAPI araması | Orta |
| **3. Docker Desktop'ın eklentileri** | Build geçmişi ve ayrıntısı, builder'lar; Scout (CVE'ler, öneriler); Hub'da arama; volume dışa/içe aktarma ve klonlama; Model Runner; MCP Toolkit; güncellemeler ve tanılama; Kubernetes durumu; uzak context'ler (SSH tüneli); Podman ve Rancher'ın farkları | Orta, eklenti başına küçük |

## 9. Performans ve güvenilirlik

CLAUDE.md'nin kuralları burada da geçerli:

- **Görünmeyen okumaz.**
  - Olay akışı ve konteyner listesi tek bağlantı. Docker çalışırken ve
    ayar açıkken açık kalır; olay yokken CPU harcamaz.
  - İstatistikler, loglar, imajlar, volume'lar ve eklenti çağrıları
    yalnızca görünürken okunur.
  - `performance` senaryosu boşta CPU'yu ölçüyor; Docker açıkken de
    geçmeli.
- **Ana thread'de beklenmez.** Ağ işi NIO'nun event loop'unda, CLI'lar bir
  GCD iş parçacığında, sonuçlar ana thread'e.
- **Büyük listeler:** imaj listesi ve gürültülü bir konteynerin logu
  (saniyede binlerce satır). Loglar son N satırı tutar, tamamı için
  terminal. Tablolar NSTableView'da (Database'in sonuç ızgarası gibi;
  binlerce satırlık bir SwiftUI listesi kaymıyor).
- **Sırlar:** Inspect ve MCP çıktısında `PASSWORD`, `SECRET`, `TOKEN`, `KEY`
  içeren env değerleri maskelenir. Kayıt defteri şifrelerine hiç
  dokunulmaz.
- **Yan etkiler:** Bir eklentiyi çalıştırmak yan etkili olabiliyor
  (`docker debug` bir imaj çekmeye başladı). Overterm eklentileri yalnızca
  kullanıcının bir eylemiyle ve belgelenmiş JSON komutlarıyla çağırır.
- **İzole çalışmalar:** E2E'de socket yolu `AppEnvironment` üzerinden
  gelir. Testler kullanıcının Docker'ına dokunmaz: ya sahte bir motor ya da
  test için kaldırılan, etiketli konteynerler.

## 10. Test

- **Saf parçalar, birim testli:**
  - context ve socket çözümü,
  - compose etiketlerinden proje ağacı,
  - log çerçevelerini ayırma, JSON log satırları,
  - tar okuma ve yazma,
  - istatistik hesabı (CPU% için iki örnek arası fark),
  - port birleştirme (IPv4/IPv6 tekrarları),
  - env maskeleme,
  - DB imajından bağlantı tahmini,
  - süzme sözdizimi (`status:running …`),
  - "Copy as `docker run`",
  - prune önizlemesi,
  - worktree çakışma tespiti.
- **Sahte Engine:** Testte bir unix socket'te Engine API'sini taklit eden
  küçük bir sunucu (BridgeServer'ın HTTP'si gibi). Liste, inspect, olaylar,
  çerçeveli loglar ve `archive` deterministik. `docker` E2E senaryosu
  bununla çalışır.
- **Eklentiler:** Gerçek çıktılardan alınmış JSON örnekleri (`buildx
  history ls`, `model list --json`, Scout'un SARIF'i).
- **Gerçek Docker:** Database testleri gibi bir ortam değişkeniyle
  (`OVERTERM_DOCKER_TESTS=1`): küçük bir `alpine` konteyneri ve iki servisli
  bir compose projesi kaldırıp siler. Konteynerler bir etiketle işaretlenir;
  yalnızca onlar temizlenir.

## 11. Riskler ve bilinmeyenler

- **Eklentilerin kararlılığı.** MCP Toolkit'in CLI'ı şimdiden değişti.
  Scout, Model ve Desktop eklentileri de Docker Desktop sürümüyle değişiyor.
  Bu yüzden 3. aşamada, her biri eklentinin varlığına ve sürümüne bakarak.
- **Podman ve Rancher.** API uyumu çoğu uç noktada aynı, ama olaylar,
  compose etiketleri ve eklentiler farklı olabilir. Bu Mac'te yalnızca
  Docker Desktop var.
- **Abonelikler.** Docker Debug Pro istiyor (biz busybox ile yapıyoruz);
  Scout'un bazı işleri giriş istiyor.
- **Compose'suz konteynerler.** `docker run` ile açılanların (`cg-test-pg`
  gibi) checkout'u yok; "diğer konteynerler"de dururlar. İstenirse elle bir
  checkout'a bağlanabilirler (2. aşama).
- **Proje adının çakışması.** İki farklı depoda aynı adlı klasör aynı
  compose projesi demek; `working_dir` ayırt eder, compose'un kendisi
  karışır.
- **Yardımcı konteyner.** Volume gezme bir imaj gerektiriyor; makinede
  yoksa çekmeden önce sorulur.
- **Kapsamın büyüklüğü.** Docker Desktop'ın hepsi, Database client'ın birkaç
  katı iş. Aşamalar bunun için.

## 12. Kararlar (2026-10-27)

1. **Arayüz:** İki katman: Docker sayfası (⌥⌘P) ve rail paneli.
2. **Docker'la konuşma:** Engine API; JSON veren eklentiler için arka
   planda CLI; görünmesi ya da kimlik istemesi gerekenler için terminal.
3. **Aşamalar:** 1. aşamaya imajlar, volume'lar ve ağlar da girer
   (liste, ayrıntı, eylemler, önizlemeli prune). Bölüm 8'in tablosu buna
   göre plan.md'de.
4. **Dışarıda kalanlar:** Eklenti mağazası, Ask Gordon, Docker Desktop'ın
   kaynak ayarları, Kubernetes arayüzü, Offload ve Hardened Images.
5. **Kısayollar:** ⌥⌘P, ⇧⌥⌘P, liste odaktayken tek harf eylemler, `/` ile
   süzme, `?` ile kopya kağıdı.
6. **Ajanlar:** Bütün araçlar: okuma ve onaylı eylemler (restart, up, down,
   rm dahil).
7. **Ortamlar:** 1. aşamada Docker Desktop, OrbStack ve Colima.
