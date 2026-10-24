# Hướng dẫn triển khai Monitor card mạng (NIC) Proxmox

Thu thập đầy đủ các thông số như lệnh `ip -s link` và `ethtool -S` trên từng node Proxmox. Dữ liệu được đẩy vào InfluxDB qua `pvestatd`, rồi hiển thị trên dashboard Grafana **Proxmox Cluster**.

## 1. Các file trong thư mục `deploy/`

| File | Vai trò |
|---|---|
| `CustomNetworkMetrics.pm` | Module Perl thu thập số liệu, được cài vào `/usr/share/perl5/PVE/` trên node |
| `deploy-monitor-nic-proxmox.sh` | Script cài, kiểm tra, chẩn đoán và gỡ trên nhiều node qua SSH |
| `nodes.txt` | Danh sách IP các node, mỗi dòng 1 IP |
| `dashboard-template.json` | Dashboard Grafana mẫu, lệnh `dashboard` dùng để tạo dashboard đúng bucket |

Cả 4 file phải nằm **cùng một thư mục** trên node (script tìm các file còn lại cạnh nó).

## 2. Cách hoạt động

![Luồng thu thập trên mỗi node](images/luong-thu-thap.svg)

Script chỉ chèn một đoạn vào `update_node_status` trong file `/usr/share/perl5/PVE/Status/InfluxDB.pm`. Script không ghi đè cả file, nên dùng được với mọi phiên bản Proxmox.

## 3. Thông số thu thập

**Bộ đếm kernel (giống `ip -s link`)**: field có tên giống hệt tên file trong `/sys/class/net/<if>/statistics/`.

| `ip -s link` | Field |
|---|---|
| RX bytes / packets | `rx_bytes`, `rx_packets` |
| RX errors / dropped / missed / mcast | `rx_errors`, `rx_dropped`, `rx_missed_errors`, `multicast` |
| TX bytes / packets | `tx_bytes`, `tx_packets` |
| TX errors / dropped / carrier / collsns | `tx_errors`, `tx_dropped`, `tx_carrier_errors`, `collisions` |
| Chi tiết lỗi | `rx_crc_errors`, `rx_length_errors`, `rx_over_errors`, `rx_fifo_errors`, `rx_frame_errors`, `rx_nohandler`, `tx_aborted_errors`, `tx_fifo_errors`, `tx_heartbeat_errors`, `tx_window_errors` |

**Counter của driver (`ethtool -S`)**: mỗi tên có thêm tiền tố `ethtool_`, các ký tự đặc biệt đổi thành `_`.

| `ethtool -S` | Field |
|---|---|
| `rx_crc_errors` | `ethtool_rx_crc_errors` |
| `veb.rx_discards` | `ethtool_veb_rx_discards` |
| `port.rx_crc_errors` | `ethtool_port_rx_crc_errors` |
| `port.tx_dropped_link_down` | `ethtool_port_tx_dropped_link_down` |
| `port.tx_hwtstamp_timeouts` | `ethtool_port_tx_hwtstamp_timeouts` |

- Chỉ lấy counter có tên chứa err, drop, discard, crc, miss, timeout, length, fifo, over, collision, carrier…
- Bỏ counter theo từng queue (`rx_queue_0_*`, `tx-0.*`) để InfluxDB không bị phình dữ liệu.
- Card ảo (`tap*`, `veth*`, `fwbr*`, `fwpr*`, `fwln*`) chỉ lấy trạng thái UP/DOWN, không lấy bộ đếm lỗi.

**Trạng thái và tốc độ link (chỉ card vật lý):**

| Field | Ý nghĩa |
|---|---|
| `network_up` | 1 = UP, 0 = DOWN |
| `link_speed` | Tốc độ link hiện tại (Mb/s), 0 khi DOWN. Lấy từ `/sys/class/net/<if>/speed` |
| `link_speed_max` | Tốc độ tối đa card hỗ trợ (Mb/s), lấy từ "Supported link modes" của `ethtool <if>`. Card 10G có giá trị `10000` kể cả khi đang DOWN |

`pvestatd` chạy liên tục, nên `link_speed_max` chỉ đọc bằng `ethtool` một lần cho mỗi card. Nếu driver không báo link mode thì dùng tốc độ cao nhất từng thấy. Trường hợp card DOWN ngay từ lúc `pvestatd` khởi động mà driver lại không báo link mode, card đó sẽ chưa hiện trên panel 10G cho tới khi có link.
- Các field cũ `hardware_drop`, `network_up`, `udp_loss`, `udp_total`, `corosync_conn` vẫn giữ nguyên tên.

## 4. Setup từng bước

Quy ước: dùng node đầu tiên `10.0.0.11` (pve1) làm nơi chạy script cho cả cluster. Các node trong cùng cluster đã SSH được sang nhau, nên thường không cần cấu hình SSH thêm. Thay IP và tên card cho đúng hệ thống.

![Quy trình cài đặt](images/quy-trinh-cai-dat.svg)

| Bước | Việc cần làm | Làm ở đâu |
|---|---|---|
| 1 | Kiểm tra Metric Server | Giao diện web Proxmox |
| 2 | Lấy bộ cài lên pve1 (git clone hoặc file zip) | pve1 hoặc máy Windows |
| 3 | Chuẩn bị | pve1 (SSH) |
| 4 | Khai báo node, kiểm tra SSH | pve1 (SSH) |
| 5 | Cài thử trên pve1 | pve1 (SSH) |
| 6 | Tạo dashboard đúng bucket, import, kiểm tra pve1 | pve1 (SSH) và Grafana |
| 7 | Cài toàn cluster | pve1 (SSH) |
| 8 | Kiểm tra toàn cluster | pve1 (SSH) và Grafana |
| 9 | Cảnh báo (tùy chọn) | Grafana |

### Bước 1: Kiểm tra Metric Server (giao diện web Proxmox)

**Datacenter → Metric Server** phải có một dòng **InfluxDB**, **Enabled = Yes**, bucket `proxmox-cluster-deco`.

- **Kết quả đúng:** có dòng InfluxDB đang bật, hoặc dashboard đang có số liệu CPU/RAM.
- **Nếu chưa có:** **Add → InfluxDB**, nhập Server, Port, Organization, Bucket, Token rồi **Create**.

### Bước 2: Lấy bộ cài lên pve1

**Cách A: node có Internet** (SSH vào pve1):

```bash
apt install -y git
git clone https://github.com/fixnhanh-linux/monitor-grafana-proxmox-cluster-influxdb.git /root/monitor-grafana-proxmox-cluster-influxdb
ln -sfn /root/monitor-grafana-proxmox-cluster-influxdb/deploy /root/monitor-nic-proxmox
```

**Cách B: node không có Internet**: tải `monitor-nic-proxmox.zip` ở mục **Releases** của repo (hoặc tự nén 4 file trong `deploy/`), rồi copy lên pve1 từ máy Windows (PowerShell):

```powershell
scp monitor-nic-proxmox.zip root@10.0.0.11:/root/
```

Lần đầu hỏi `yes/no` thì gõ `yes`, rồi nhập mật khẩu root. Không có `scp` thì dùng WinSCP kéo thả file vào `/root/`.

### Bước 3: Chuẩn bị (SSH vào pve1)

`ssh root@10.0.0.11`. Từ đây mọi lệnh chạy trên pve1. Nếu dùng **cách B**, giải nén trước:

```bash
command -v unzip || apt install -y unzip
unzip -o /root/monitor-nic-proxmox.zip -d /root/monitor-nic-proxmox
```

Sau đó (cả hai cách):

```bash
cd /root/monitor-nic-proxmox
chmod +x deploy-monitor-nic-proxmox.sh
ls -l
command -v ethtool || apt install -y ethtool
```

- **Kết quả đúng:** `ls -l` có 4 file (gồm `dashboard-template.json`), `deploy-monitor-nic-proxmox.sh` có quyền `-rwxr-xr-x`; lệnh cuối in `/usr/sbin/ethtool`.
- **Nếu lỗi:** `unzip` báo `End-of-central-directory signature not found` là file hỏng khi copy, copy lại. Node không có Internet để `apt install unzip` thì copy 4 file lẻ bằng WinSCP vào `/root/monitor-nic-proxmox/`. Báo `$'\r': command not found` thì chạy `sed -i 's/\r$//' *.sh *.pm`.

### Bước 4: Khai báo node và kiểm tra SSH (pve1)

Lấy IP các node:

```bash
pvecm status | sed -n '/Membership information/,$p'
```

Điền IP vào `nodes.txt`, mỗi dòng một IP (lưu: Ctrl+O, Enter; thoát: Ctrl+X):

```bash
nano nodes.txt
```

Kiểm tra SSH không cần mật khẩu (chạy trong `/root/monitor-nic-proxmox`):

```bash
for ip in $(awk 'NF && $1 !~ /^#/ {print $1}' nodes.txt); do
  echo -n "$ip -> "; ssh -o BatchMode=yes -o ConnectTimeout=5 root@$ip hostname
done
```

- **Kết quả đúng:** mỗi IP in đúng tên node.
- **Nếu lỗi `Permission denied`:** `ssh-copy-id root@<ip>`, hoặc `apt install sshpass` rồi `export SSH_PASS='mat_khau'`.

### Bước 5: Cài thử trên pve1 (pve1)

Ghi lại số liệu gốc để đối chiếu:

```bash
ip -s link show enp24s0f2np2
```

Cài:

```bash
./deploy-monitor-nic-proxmox.sh install 10.0.0.11
```

Kết quả mẫu:

```
==> 10.0.0.11 (install)
[pve1]
  [OK] Da cai /usr/share/perl5/PVE/CustomNetworkMetrics.pm
  [OK] Da patch InfluxDB.pm (backup: /usr/share/perl5/PVE/Status/InfluxDB.pm.bak)
  [OK] Co /usr/share/perl5/PVE/CustomNetworkMetrics.pm
  [OK] InfluxDB.pm da duoc patch
  [OK] Co ethtool
  [OK] pvestatd dang chay
  udp_loss=0 corosync_conn=4
  enp24s0f2np2     UP    10000/10000  rx_errors=67 rx_dropped=685 tx_dropped=878 rx_crc=67 (+17 counter ethtool)
Hoan thanh: 1 node OK
```

- **Kết quả đúng:** mọi dòng `[OK]`; số liệu khớp `ip -s link`.
- **Nếu có `[LOI]`:** xem [bảng sự cố khi triển khai](02-Canh-Bao-Va-Xu-Ly-Su-Co-Card-Mang.md#3-sự-cố-khi-triển-khai). Nếu lỗi ở bước patch, script không ghi đè `InfluxDB.pm`.

### Bước 6: Tạo dashboard đúng bucket và import (pve1, Grafana)

Dashboard mẫu dùng bucket `proxmox-cluster-deco`. Mỗi cluster có thể gửi vào bucket khác (xem `cat /etc/pve/status.cfg`, dòng `bucket`), nên tạo dashboard riêng cho cluster bằng lệnh `dashboard`. Lệnh tự đọc bucket từ `status.cfg`:

```bash
cd /root/monitor-nic-proxmox
./deploy-monitor-nic-proxmox.sh dashboard
```

Kết quả: file `dashboard-<bucket>.json` (ví dụ `dashboard-demo.json`), title `Proxmox Cluster <bucket>`, uid riêng nên không ghi đè dashboard của cluster khác. Mọi panel dùng biến datasource, không gắn cứng datasource của Grafana cũ.

**Cách 1: script import luôn** (cần token Grafana: Administration → Service accounts → Add → role Editor → Add token):

```bash
export GRAFANA_URL=https://<IP-Grafana>:3000
export GRAFANA_TOKEN='glsa_xxx'
export GRAFANA_DS='ten-datasource-influxdb'   # tuy chon: ten datasource Flux tro toi bucket nay
./deploy-monitor-nic-proxmox.sh dashboard
```

**Cách 2: import tay:** copy file về Windows rồi Dashboards → New → Import → Upload:

```powershell
scp root@10.0.0.11:/root/monitor-nic-proxmox/dashboard-demo.json .
```

Mở dashboard, chọn **Datasource** (datasource InfluxDB Flux trỏ tới bucket của cluster), **Server** = pve1, thời gian **Last 15 minutes**.

- **Kết quả đúng:** panel "Physical NIC Link Status (10G+)" hiện card 10G/25G; bảng "NIC Counters – ip -s link" khớp `ip -s link`.
- **Nếu trống:** kiểm tra đã chọn đúng Datasource, đợi thêm 1 phút, chạy `./deploy-monitor-nic-proxmox.sh check <ip-pve1>`.

### Bước 7: Cài toàn cluster (pve1)

```bash
./deploy-monitor-nic-proxmox.sh install -f nodes.txt
```

- **Kết quả đúng:** `Hoan thanh: 8 node OK`.
- **Nếu có node lỗi:** đọc output của node đó, sửa, chạy lại riêng: `./deploy-monitor-nic-proxmox.sh install <ip>`.

### Bước 8: Kiểm tra toàn cluster (pve1 và Grafana)

```bash
./deploy-monitor-nic-proxmox.sh check -f nodes.txt
```

Mọi node `[OK]`; trên Grafana đổi Server qua từng node đều có số liệu.

Không truyền tham số (`./deploy-monitor-nic-proxmox.sh check`) thì script tự dùng `nodes.txt` nằm cùng thư mục với script, chạy ở thư mục nào cũng được. Khi dùng `-f` thì phải có tên file ngay sau: `-f nodes.txt`.

### Chẩn đoán khi Grafana không có số liệu

```bash
./deploy-monitor-nic-proxmox.sh diag -f nodes.txt
```

![Lệnh diag kiểm tra lần lượt](images/quy-trinh-diag.svg)

Lệnh chạy trên từng node, tự đọc cấu hình InfluxDB (server, port, org, bucket, token) trong Proxmox rồi kiểm tra lần lượt: module/patch → cấu hình Metric Server (cảnh báo timeout quá ngắn) → log `pvestatd` → kết nối InfluxDB → dữ liệu gốc (`cpustat`) và dữ liệu NIC mới trong bucket. Dòng **Ket luan** cuối cùng cho biết lỗi nằm ở đâu và cách xử lý.

### Bước 9: Cảnh báo (tùy chọn)

Xem [Cảnh báo và xử lý sự cố](02-Canh-Bao-Va-Xu-Ly-Su-Co-Card-Mang.md#1-cảnh-báo-grafana-alerting).

![Lệnh install làm gì trên mỗi node](images/logic-install.svg)

**Script làm gì trên mỗi node:** cài module vào `/usr/share/perl5/PVE/`, backup `InfluxDB.pm` thành `.bak` (chỉ lần đầu), patch `InfluxDB.pm` nếu chưa patch (kiểm tra `perl -c`, lỗi thì không ghi đè), restart `pvestatd`, rồi tự kiểm tra.

## 5. Kiểm tra

**Trên các node:**

```bash
./deploy-monitor-nic-proxmox.sh check -f nodes.txt
```

**Xem log pvestatd trên node:**

```bash
journalctl -u pvestatd -n 50
```

**Kiểm tra dữ liệu trong InfluxDB** (Data Explorer, Flux):

```flux
from(bucket: "proxmox-cluster-deco")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "nics" and r.instance == "enp24s0f2np2")
  |> last()
```

## 6. Dashboard Grafana

Import `dashboard-<bucket>.json` do lệnh `dashboard` tạo (Bước 6). Mọi panel NIC đều bằng tiếng Anh và **chỉ hiện card vật lý** (card có `link_speed_max`), không hiện `br-*`, `docker0`, `ovs-system`, `vmbr*`, `bond*`.

| Panel | Kiểu | Nội dung |
|---|---|---|
| Physical NIC Link Status (10G+) | Stat | Card 10G trở lên: tên kèm tốc độ tối đa (`[25G]`), giá trị là tốc độ hiện tại |
| NIC Link Status Timeline | State timeline | UP/DOWN và tốc độ của từng card theo thời gian, thấy rõ lúc link flap hoặc đổi tốc độ |
| NIC Error Timeline (new errors per interval) | State timeline | Mỗi card một dòng: xanh `OK` = không có lỗi mới, đỏ = số lỗi mới trong khoảng đó |
| NIC Counters - ip -s link (cumulative since boot) | Bảng | Đủ cột như `ip -s link`, xếp theo thứ tự: Link, Speed, Max Speed, RX Errors, RX CRC Errors… cuối cùng là bytes/packets. Ô lỗi khác 0 tô đỏ |
| NIC RX Errors - CRC / Length / Missed / Overrun | Cột | Lỗi RX mới mỗi khoảng thời gian |
| NIC Drops & TX Errors - Dropped / Carrier / Collisions | Cột | Gói rớt và lỗi TX mới mỗi khoảng thời gian |
| NIC Driver Counters - ethtool -S (non-zero, cumulative) | Bảng | Counter `ethtool -S` khác 0 |
| NIC Driver Counters - ethtool -S (new per interval) | Cột | Chỉ vẽ counter `ethtool` có tăng |

Màu tốc độ link: xanh = UP từ 10G, cam = UP nhưng dưới 10G (kiểm tra cáp/SFP/port switch), đỏ = DOWN. Card 25G chạy ở 10G hiện `UP 10G` màu xanh, tên có `[25G]` để phân biệt.

**Cách đọc số:**

- **Số tích lũy và số tăng:** số tích lũy (ví dụ `rx_errors = 67`) có thể là lỗi cũ từ lần boot trước. Cần xem biểu đồ "tăng mỗi chu kỳ" để biết lỗi còn đang phát sinh hay không.
- **`rx_crc_errors`, `rx_length_errors`, `port.rx_crc_errors` tăng:** thường là lỗi lớp vật lý. Kiểm tra cáp/DAC, module SFP, port switch, và xem counter phía switch.
- **`rx_dropped` của kernel khác `ethtool rx_dropped`:** bộ đếm kernel tính cả gói bị bỏ ở tầng phần mềm, như VLAN hoặc protocol không xử lý. Con số này thường lớn hơn bộ đếm của driver.
- **`tx_dropped` tăng:** hàng đợi gửi bị đầy, hoặc gói bị bỏ khi link down (`port.tx_dropped_link_down`).

## 7. Lưu ý vận hành

- **Nâng cấp Proxmox** (`apt upgrade` có `pve-manager`) sẽ ghi đè `InfluxDB.pm` làm mất patch, dashboard ngừng có số liệu mới. Sau mỗi lần nâng cấp, chạy lại:
  ```bash
  ./deploy-monitor-nic-proxmox.sh install -f nodes.txt
  ```
- **Sửa module:** chỉ cần sửa `CustomNetworkMetrics.pm` rồi chạy lại `install`. Phần patch `InfluxDB.pm` không bị chèn trùng.
- **Gửi dữ liệu chậm (timeout):** nếu InfluxDB gửi bị timeout, tăng `timeout` cho metric server trong *Datacenter → Metric Server*. Không nên tự nối dòng vào `/etc/pve/status.cfg`.

## 8. Gỡ bỏ

```bash
./deploy-monitor-nic-proxmox.sh uninstall -f nodes.txt
```

Script khôi phục `InfluxDB.pm` gốc bằng cách reinstall package chứa file đó (`pve-manager`). Nếu không reinstall được thì dùng `InfluxDB.pm.bak`. Sau đó script xóa module và restart `pvestatd`.
