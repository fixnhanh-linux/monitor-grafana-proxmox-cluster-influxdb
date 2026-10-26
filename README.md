# Hướng Dẫn Giám Sát Card Mạng Proxmox Cluster Bằng InfluxDB Và Grafana

Thu thập đầy đủ thông số như `ip -s link` và `ethtool -S`, trạng thái UP/DOWN và tốc độ link card 10G/25G trên **mọi node** của cluster Proxmox VE. Dữ liệu đi thẳng vào InfluxDB qua tiến trình `pvestatd` có sẵn của Proxmox và hiển thị trên Grafana. **Không cần cài agent.**

**Mục lục:**
[Giới thiệu](#1-giới-thiệu) ·
[Kiến trúc](#2-kiến-trúc) ·
[Thông số thu thập](#3-thông-số-thu-thập) ·
[Yêu cầu](#4-yêu-cầu) ·
[Cài đặt nhanh](#6-cài-đặt-nhanh) ·
[Lệnh của script](#7-các-lệnh-của-script) ·
[Dashboard](#8-dashboard-grafana) ·
[Cảnh báo](#9-cảnh-báo) ·
[Vận hành](#10-vận-hành) ·
[Tài liệu chi tiết](#11-tài-liệu-chi-tiết)

---

## 1. Giới thiệu

Metric mặc định mà Proxmox gửi sang InfluxDB chỉ có **băng thông TX/RX**. Khi cluster gặp sự cố mạng như cáp lỗi, SFP bẩn, link chập chờn hay card 25G chạy tụt xuống 10G, dashboard thường **không thấy gì bất thường**.

Bộ công cụ này bổ sung các chỉ số mạng ở mức thấp vào ngay luồng metric gốc của Proxmox:

| Vấn đề thường gặp | Thấy được qua |
|---|---|
| Cáp/DAC hỏng, SFP bẩn | `rx_crc_errors`, `port.rx_crc_errors` tăng theo thời gian |
| Link chập chờn (flapping) | Panel NIC Link Status và NIC Link Speed theo thời gian |
| Card 25G chỉ chạy 10G | So sánh `link_speed` với `link_speed_max` |
| Ring buffer đầy, CPU xử lý không kịp | `rx_missed_errors`, `rx_fifo_errors` |
| Corosync mất một link (link0/link1) | `corosync_links_up` nhỏ hơn `corosync_links`, panel Corosync Links / Corosync Link Timeline |
| Gói UDP Corosync bị mất | `udp_loss` |

**Điểm mạnh:**

- **Chạy native:** nằm trong `pvestatd` của Proxmox, không cài Telegraf, node_exporter hay vòng lặp bash.
- **Triển khai hàng loạt:** một lệnh cài cho cả cluster qua SSH.
- **An toàn:** kiểm tra `perl -c` trước khi ghi, có backup `.bak`, chạy lại không bị chèn trùng, gỡ sạch được.
- **Tự chẩn đoán:** lệnh `diag` chỉ ra lỗi nằm ở module, cấu hình, kết nối hay InfluxDB.
- **Dashboard sẵn:** tự sinh đúng bucket và datasource cho từng cluster.

---

## 2. Kiến trúc

### 2.1. Tổng quan hệ thống

Admin chạy script trên một node để cài module lên toàn cluster qua SSH. Sau đó mỗi node tự gửi số liệu sang InfluxDB 10 giây/lần, Grafana đọc bằng Flux để vẽ dashboard và gửi cảnh báo.

<p align="center"><img src="docs/images/kien-truc-tong-quan.svg" alt="Kiến trúc tổng quan" width="100%"></p>

### 2.2. Luồng thu thập trên mỗi node

Mỗi chu kỳ, `pvestatd` gọi `update_node_status()` trong plugin InfluxDB của Proxmox. Đoạn patch gọi thêm module `CustomNetworkMetrics`, module đọc 4 nguồn số liệu rồi gắn vào measurement `nics` (theo từng card) và `system` (theo node).

<p align="center"><img src="docs/images/luong-thu-thap.svg" alt="Luồng thu thập trên mỗi node" width="100%"></p>

Script chỉ **chèn một đoạn nhỏ** vào hàm `update_node_status` trong `/usr/share/perl5/PVE/Status/InfluxDB.pm`, không ghi đè cả file, nên dùng được với nhiều phiên bản Proxmox. Module bắt mọi lỗi bên trong: nếu đọc số liệu lỗi thì `pvestatd` vẫn chạy bình thường.

### 2.3. Lệnh `install` làm gì trên mỗi node

<p align="center"><img src="docs/images/logic-install.svg" alt="Lệnh install làm gì trên mỗi node" width="70%"></p>

---

## 3. Thông số thu thập

### 3.1. Card mạng: measurement `nics`

Tag: `host` (tên node), `instance` (tên card, ví dụ `enp24s0f2np2`).

**Bộ đếm kernel (giống `ip -s link`)**

| `ip -s link` | Field |
|---|---|
| RX bytes / packets | `rx_bytes`, `rx_packets` |
| RX errors / dropped / missed / mcast | `rx_errors`, `rx_dropped`, `rx_missed_errors`, `multicast` |
| TX bytes / packets | `tx_bytes`, `tx_packets` |
| TX errors / dropped / carrier / collsns | `tx_errors`, `tx_dropped`, `tx_carrier_errors`, `collisions` |
| Chi tiết lỗi | `rx_crc_errors`, `rx_length_errors`, `rx_over_errors`, `rx_fifo_errors`, `rx_frame_errors`, `rx_nohandler`, `tx_aborted_errors`, `tx_fifo_errors`, `tx_heartbeat_errors`, `tx_window_errors` |

**Counter driver (`ethtool -S`, chỉ card vật lý)**: mỗi tên có thêm tiền tố `ethtool_`, ký tự đặc biệt đổi thành `_`.

| `ethtool -S` | Field |
|---|---|
| `rx_crc_errors` | `ethtool_rx_crc_errors` |
| `veb.rx_discards` | `ethtool_veb_rx_discards` |
| `port.rx_crc_errors` | `ethtool_port_rx_crc_errors` |
| `port.tx_dropped_link_down` | `ethtool_port_tx_dropped_link_down` |

- Chỉ lấy counter có tên chứa *err, drop, discard, crc, miss, timeout, length, fifo, over, collision, carrier…*
- Bỏ counter theo từng queue (`rx_queue_0_*`, `tx-0.*`) để InfluxDB không bị phình.

**Trạng thái và tốc độ link**

| Field | Ý nghĩa |
|---|---|
| `network_up` | `1` = UP, `0` = DOWN |
| `link_speed` | Tốc độ hiện tại (Mb/s), `0` khi DOWN |
| `link_speed_max` | Tốc độ tối đa card hỗ trợ (Mb/s). Card 10G luôn là `10000`, kể cả khi DOWN |
| `hardware_drop` | Số gói rớt (RX dropped) |

Card ảo (`tap*`, `veth*`, `fwbr*`, `fwpr*`, `fwln*`) chỉ lấy trạng thái UP/DOWN, không lấy bộ đếm lỗi.

### 3.2. Hệ thống: measurement `system`

| Field | Ý nghĩa |
|---|---|
| `udp_loss` | Số gói UDP lỗi/rớt (`InErrors` trong `/proc/net/snmp`) |
| `udp_total` | Tổng gói UDP đã nhận (`InDatagrams`) |
| `corosync_conn` | Số socket UDP Corosync đang mở (cổng 5404/5405). Chỉ để tham khảo, không cho biết link có thông |
| `corosync_links` | Số link Corosync đang cấu hình (link0, link1…), đọc từ `corosync-cfgtool -s` |
| `corosync_links_up` | Số link tới được **mọi** node khác. Cluster 2 link khỏe = `2` |
| `corosync_link<N>_peers` | Số node khác trong cluster (theo link N) |
| `corosync_link<N>_connected` | Số node kết nối được qua link N |
| `corosync_link<N>_up` | `1` = link N tới được mọi node, `0` = mất ít nhất 1 node |
| `corosync_link<N>_iface` | Card mạng mà link N chạy qua (theo IP của link), ví dụ `vmbr0`, `nic2` |

Ví dụ cluster có 2 link: link0 chạy chung cặp card 10G (`vmbr0`), link1 chạy riêng card 1G `nic2`. Khi cả hai khỏe, `corosync_links_up = 2`. Mất `nic2` thì giá trị còn `1`, panel Corosync Links chuyển sang `▲ DEGRADED 1/2`, cluster vẫn chạy trên link0.

---

## 4. Yêu cầu

| Thành phần | Yêu cầu |
|---|---|
| Proxmox VE | Đã cấu hình **Datacenter → Metric Server** loại **InfluxDB**, đang bật |
| InfluxDB | 2.x, có bucket, org và token ghi dữ liệu |
| Grafana | Datasource InfluxDB, ngôn ngữ truy vấn **Flux**, trỏ tới bucket trên |
| Trên node | Quyền `root`, có `ethtool` |
| SSH | Từ node chạy script tới các node: SSH key, hoặc mật khẩu + `sshpass` |

---

## 5. Cấu trúc repo

```
monitor-grafana-proxmox-cluster-influxdb/
├── install.sh                                    Cài cả cluster bằng 1 lệnh (bắt đầu ở đây)
├── README.md                                     Tổng quan (file này)
├── deploy/                                       Bộ cài lên node Proxmox
│   ├── CustomNetworkMetrics.pm                   Module Perl thu thập số liệu
│   ├── deploy-monitor-nic-proxmox.sh             install / check / diag / dashboard / uninstall
│   └── nodes.txt                                 Danh sách IP node (install.sh tự điền nếu để trống)
├── dashboard-grafana/                            Dashboard Grafana
│   ├── proxmox-cluster-dashboard.json            Dashboard mẫu (file duy nhất)
│   ├── import-dashboard.sh                       Tạo + import dashboard đúng bucket/datasource
│   ├── export-dashboard.sh                       Lấy dashboard từ Grafana về repo sau khi sửa giao diện
│   └── Huong-Dan-Import-Dashboard-Grafana.md     Hướng dẫn import / export dashboard
└── docs/
    ├── 01-Huong-Dan-Trien-Khai-Monitor-NIC-Proxmox.md   Hướng dẫn từng bước
    ├── 02-Canh-Bao-Va-Xu-Ly-Su-Co-Card-Mang.md          Alert Grafana, đọc lỗi, xử lý sự cố, vận hành
    ├── 03-Cai-Dat-Thu-Cong-Patch-InfluxDB.md            Patch thủ công, giải thích nguyên lý
    └── images/                                          Sơ đồ SVG
```

> Luôn `git clone` **cả repo** lên node: script trong `deploy/` dùng dashboard ở `dashboard-grafana/`.

---

## 6. Cài đặt nhanh

### 6.1. Quy trình

<p align="center"><img src="docs/images/quy-trinh-cai-dat.svg" alt="Quy trình cài đặt" width="100%"></p>

### 6.2. Cài bằng 1 lệnh (khuyên dùng)

Chạy trên node đầu tiên của cluster bằng `root`:

```bash
apt install -y git
git clone https://github.com/fixnhanh-linux/monitor-grafana-proxmox-cluster-influxdb.git /root/nic-monitor

# (tùy chọn) import dashboard luôn vào Grafana
export GRAFANA_URL=https://<IP-Grafana>:3000
export GRAFANA_TOKEN='glsa_xxx'        # Administration → Service accounts → role Editor

bash /root/nic-monitor/install.sh
```

`install.sh` tự làm 5 bước:

| Bước | Việc | Ghi chú |
|---|---|---|
| 1 | Kiểm tra root, Proxmox, Metric Server InfluxDB; cài `ethtool`, `python3`, `curl` nếu thiếu | Sửa luôn file bị CRLF khi copy qua Windows |
| 2 | Lấy IP các node đang online (`pvesh get /cluster/status`), ghi vào `deploy/nodes.txt` | Đã có IP trong `nodes.txt` thì dùng danh sách đó |
| 3 | Cài module lên từng node | Giống `deploy-monitor-nic-proxmox.sh install -f nodes.txt` |
| 4 | Kiểm tra từng node | Giống lệnh `check` |
| 5 | Tạo dashboard đúng bucket trong `/etc/pve/status.cfg`, import nếu có `GRAFANA_URL` + `GRAFANA_TOKEN` | Không có token thì chỉ tạo file JSON |

| Tùy chọn | Tác dụng |
|---|---|
| `-y` | Không hỏi xác nhận |
| `-n "10.0.0.11 10.0.0.12"` | Chỉ cài các node này |
| `--no-dashboard` | Bỏ qua bước dashboard (dùng khi cài lại sau `apt upgrade`) |

### 6.3. Cài từng bước (thủ công)

```bash
cd /root/nic-monitor/deploy

# Khai báo IP các node, mỗi dòng 1 IP
pvecm status | sed -n '/Membership information/,$p'
nano nodes.txt

# Cài thử 1 node, output phải toàn [OK]
bash deploy-monitor-nic-proxmox.sh install 10.0.0.11

# Tạo dashboard đúng bucket của cluster (đọc từ /etc/pve/status.cfg)
bash deploy-monitor-nic-proxmox.sh dashboard

# Cài cho cả cluster rồi kiểm tra
bash deploy-monitor-nic-proxmox.sh install -f nodes.txt
bash deploy-monitor-nic-proxmox.sh check   -f nodes.txt
```

Kết quả mẫu khi cài thành công:

```
==> 10.0.0.11 (install)
[pve1]
  [OK] Da cai /usr/share/perl5/PVE/CustomNetworkMetrics.pm
  [OK] Da patch InfluxDB.pm (backup: /usr/share/perl5/PVE/Status/InfluxDB.pm.bak)
  [OK] Co ethtool
  [OK] pvestatd dang chay
  udp_loss=0 corosync_conn=2
  corosync: 2/2 link UP
    link0  vmbr0        UP   2/2 node ket noi
    link1  nic2         UP   2/2 node ket noi
  enp24s0f2np2     UP    10000/10000  rx_errors=67 rx_dropped=685 tx_dropped=878 rx_crc=67 (+17 counter ethtool)
Hoan thanh: 1 node OK
```

> **Node không có Internet?** Tải `monitor-nic-proxmox.zip` ở mục **Releases**, `scp` lên node rồi giải nén. Xem [hướng dẫn triển khai, bước 2](docs/01-Huong-Dan-Trien-Khai-Monitor-NIC-Proxmox.md#bước-2-lấy-bộ-cài-lên-pve1).

### 6.4. Import dashboard

```bash
cd /root/nic-monitor/dashboard-grafana

# Hỏi URL, token, datasource rồi import (bỏ trống URL = chỉ tạo file JSON)
bash import-dashboard.sh -b <ten-bucket>

# Hoặc truyền sẵn, không hỏi
bash import-dashboard.sh -u https://<IP-Grafana>:3000 -t 'glsa_xxx' -d 'ten-datasource' -b <ten-bucket> -f Proxmox -y
```

Import tay: Grafana → **Dashboards → New → Import → Upload** file `dashboard-grafana/proxmox-cluster-dashboard.json`. Chi tiết: [Hướng dẫn import dashboard](dashboard-grafana/Huong-Dan-Import-Dashboard-Grafana.md).

---

## 7. Các lệnh của script

| Lệnh | Tác dụng |
|---|---|
| `install [-f nodes.txt \| ip...]` | Cài module, patch `InfluxDB.pm` (có backup), restart `pvestatd`, tự kiểm tra |
| `check [-f nodes.txt \| ip...]` | Kiểm tra module, patch, ethtool, pvestatd và in số liệu từng card |
| `diag [-f nodes.txt \| ip...]` | Chẩn đoán vì sao Grafana không có số liệu |
| `dashboard [bucket]` | Gọi `dashboard-grafana/import-dashboard.sh`: tạo `dashboard-<bucket>.json`, có `GRAFANA_URL` + `GRAFANA_TOKEN` thì import luôn |
| `uninstall [-f nodes.txt \| ip...]` | Khôi phục `InfluxDB.pm` gốc, xóa module, restart `pvestatd` |

Không truyền node thì script dùng `nodes.txt` nằm cạnh script.

Các script khác:

| Script | Tác dụng |
|---|---|
| `install.sh` | Cài cả cluster bằng 1 lệnh (mục 6.2) |
| `dashboard-grafana/import-dashboard.sh` | Tạo dashboard đúng bucket/datasource, import qua API, tạo thư mục Grafana nếu cần |
| `dashboard-grafana/export-dashboard.sh` | Lấy dashboard từ Grafana về, làm sạch (bỏ UID/datasource/bucket riêng), ghi đè `proxmox-cluster-dashboard.json` |

| Biến môi trường | Mặc định | Ý nghĩa |
|---|---|---|
| `SSH_USER` | `root` | User SSH tới các node |
| `SSH_PASS` | (trống) | Mật khẩu SSH, cần cài `sshpass` |
| `GRAFANA_URL` | (trống) | URL Grafana để import dashboard |
| `GRAFANA_TOKEN` | (trống) | Token service account Grafana |
| `GRAFANA_DS` | (trống) | Tên datasource InfluxDB gắn vào dashboard |
| `GRAFANA_FOLDER` | (trống) | Thư mục Grafana lưu dashboard (chưa có thì tự tạo) |

### Lệnh `diag` kiểm tra lần lượt

<p align="center"><img src="docs/images/quy-trinh-diag.svg" alt="Lệnh diag kiểm tra lần lượt" width="100%"></p>

Dòng **Ket luan** cuối cùng của lệnh cho biết lỗi nằm ở bước nào và cách xử lý.

---

## 8. Dashboard Grafana

Dashboard giữ các panel tổng quan của Proxmox (CPU, RAM, storage, VM) và thêm nhóm panel NIC. Các panel NIC **chỉ hiện card vật lý**, không hiện `vmbr*`, `bond*`, `br-*`, `docker0`.

| Panel | Kiểu | Nội dung |
|---|---|---|
| NIC Link Status | State timeline | Mỗi card vật lý một thanh (1G, 10G, 25G…), tên kèm tốc độ tối đa (`nic2 [1G]`, `ens3f0np0 [25G]`). Gộp trạng thái link và lỗi: `✔ UP 10G` (xanh, đúng tốc độ tối đa của card) · `▲ UP 10G (below max)` (cam, chạy dưới tốc độ tối đa) · `⚠ … · 1–99 Errors` (vàng) · `▲ … · 100–999 Errors` (cam) · `⛔ … · 1K+ Errors` / `⛔ DOWN` (đỏ) |
| NIC Link Speed | Time series | Tốc độ link theo thời gian, vạch nét đứt ở 10G. Tụt về 0 = DOWN, bước xuống = đổi tốc độ. Cột `Min` = 0 nghĩa là đã có lúc rớt link |
| Corosync Links | Stat | `✔ UP 2/2` (xanh) = mọi link Corosync tới được mọi node · `▲ DEGRADED 1/2` (cam) = một link mất node · `⛔ DOWN` (đỏ) |
| Corosync Link Timeline | State timeline | Mỗi link một thanh kèm card, ví dụ `link0 (vmbr0)`, `link1 (nic2)`: `✔ UP 2/2 nodes` / `▲ DEGRADED 1/2 nodes` / `⛔ DOWN` theo thời gian |
| UDP Packet Loss | Stat | Gói UDP lỗi/rớt trên node |
| Hardware RX Drops (Cumulative) | Time series | Gói RX bị rớt (tích lũy) theo từng interface |
| NIC Link & Traffic (Since Boot) | Bảng | Link, Speed, Max Speed, RX/TX Bytes, RX/TX Packets, Multicast. Link/Speed tô màu theo trạng thái |
| NIC RX Errors (Since Boot) | Bảng | Errors, CRC, Length, Missed, Dropped, Overrun, FIFO, Frame, No Handler |
| NIC TX Errors (Since Boot) | Bảng | Errors, Dropped, Carrier, Aborted, FIFO, Heartbeat, Window, Collisions |
| NIC RX Errors (Per Interval) | Cột chồng | Lỗi RX **mới** mỗi khoảng thời gian, tên dạng `ens3f0np0 · CRC`, bảng chú thích xếp theo Total giảm dần |
| NIC TX Errors & Drops (Per Interval) | Cột chồng | Lỗi TX và gói rớt **mới** mỗi khoảng thời gian |
| Ethtool Counters (Since Boot) | Bảng | Counter `ethtool -S` khác 0 (bỏ tiền tố `ethtool_`), cột Count dạng thanh đo màu |
| Ethtool Counters (Per Interval) | Cột | Mức tăng của các counter `ethtool` khác 0; đường phẳng ở 0 = không tăng |

**Mức cảnh báo (bảng lỗi và counter):** 🟩 0 = OK · 🟨 1–99 = chú ý · 🟧 100–999 = cảnh báo · 🟥 1.000–9.999 = nghiêm trọng · đỏ đậm ≥ 10.000.

**Màu tốc độ link:** xanh lá = UP đúng tốc độ tối đa của chính card đó (card 1G chạy 1G cũng xanh) · cam `(below max)` = UP nhưng chậm hơn khả năng của card, ví dụ card 25G chạy 10G (kiểm tra cáp/SFP/port switch) · đỏ = DOWN.

Mỗi panel có nút ⓘ giải thích bằng tiếng Anh ý nghĩa và nguyên nhân thường gặp của từng loại lỗi.

> **Cách đọc số:** số tích lũy (ví dụ `rx_errors = 67`) có thể là lỗi cũ từ lần boot trước. Hãy xem các biểu đồ **"new per interval"** để biết lỗi **còn đang phát sinh** hay không.

---

## 9. Cảnh báo

Nên tạo ba Alert rule trong Grafana. Truy vấn Flux đầy đủ có trong [tài liệu cảnh báo và xử lý sự cố](docs/02-Canh-Bao-Va-Xu-Ly-Su-Co-Card-Mang.md#1-cảnh-báo-grafana-alerting).

| Cảnh báo | Điều kiện |
|---|---|
| Card 10G mất link | `network_up` của card có `link_speed_max >= 10000` nhỏ hơn 1 trong 1 phút |
| Lỗi CRC / RX errors đang tăng | Tổng lỗi mới trong 15 phút lớn hơn 0 (hoặc ngưỡng 10) |
| Corosync mất link | `corosync_links_up` nhỏ hơn `corosync_links` trong 1 phút |

---

## 10. Vận hành

> **Quan trọng:** mỗi lần `apt upgrade` có nâng cấp `pve-manager`, file `InfluxDB.pm` sẽ bị ghi đè và **mất patch**. Dấu hiệu: panel NIC không còn dữ liệu mới, trong khi CPU/RAM vẫn bình thường.

```bash
./deploy-monitor-nic-proxmox.sh check   -f nodes.txt   # node nào báo [THIEU] là đã mất patch
./deploy-monitor-nic-proxmox.sh install -f nodes.txt   # chạy lại luôn an toàn
```

| Tình huống | Việc cần làm |
|---|---|
| Thêm node mới | Thêm IP vào `nodes.txt`, chạy `install <ip-node-moi>` |
| Sửa module | Sửa `CustomNetworkMetrics.pm`, kiểm tra `perl -c`, chạy lại `install` |
| InfluxDB báo timeout | Tăng timeout ở **Datacenter → Metric Server → Edit** |
| Gỡ bỏ | `./deploy-monitor-nic-proxmox.sh uninstall -f nodes.txt` |

**Sự cố thường gặp**

| Hiện tượng | Cách xử lý |
|---|---|
| `$'\r': command not found` | File bị đổi sang CRLF khi copy qua Windows: `sed -i 's/\r$//' *.sh *.pm` |
| `Permission denied` khi SSH | `ssh-copy-id root@<ip>`, hoặc `export SSH_PASS='...'` và cài `sshpass` |
| Không có field `ethtool_*` | `apt install ethtool` rồi chạy lại `install` |
| Dashboard trống | Chọn đúng Datasource/bucket, rồi chạy `diag -f nodes.txt` |

Bảng đầy đủ: [tài liệu cảnh báo và xử lý sự cố](docs/02-Canh-Bao-Va-Xu-Ly-Su-Co-Card-Mang.md#3-sự-cố-khi-triển-khai).

---

## 11. Tài liệu chi tiết

| # | Tài liệu | Nội dung |
|---|---|---|
| 01 | [Hướng dẫn triển khai Monitor NIC Proxmox](docs/01-Huong-Dan-Trien-Khai-Monitor-NIC-Proxmox.md) | Từng bước từ kiểm tra Metric Server tới cài toàn cluster, kết quả đúng và cách sửa ở mỗi bước |
| 02 | [Cảnh báo và xử lý sự cố card mạng](docs/02-Canh-Bao-Va-Xu-Ly-Su-Co-Card-Mang.md) | Alert Grafana, ý nghĩa từng loại lỗi card mạng, quy trình xử lý lỗi CRC, vận hành, checklist |
| 03 | [Cài đặt thủ công: patch InfluxDB.pm](docs/03-Cai-Dat-Thu-Cong-Patch-InfluxDB.md) | Patch tay `InfluxDB.pm`, giải thích nguyên lý hoạt động |

> Không commit token Grafana/InfluxDB hay IP thật vào repo.
