# monitor-grafana-proxmox-cluster-influxdb

Giám sát card mạng (NIC) trên cluster Proxmox VE: thu thập đầy đủ thông số như `ip -s link` và `ethtool -S`, trạng thái UP/DOWN và tốc độ link của card 10G/25G, đẩy thẳng vào InfluxDB qua `pvestatd` có sẵn của Proxmox và hiển thị trên Grafana.

Không cần cài Telegraf hay agent nào khác.

```
pvestatd (10 giây/lần)
  └─ PVE::Status::InfluxDB::update_node_status()
       └─ PVE::CustomNetworkMetrics::get_metrics()   <- module thêm vào
            ├─ /sys/class/net/<if>/statistics/*      (giống ip -s link)
            ├─ ethtool -S <if>  (chỉ card vật lý)
            └─ /proc/net/snmp, ss                    (udp_loss, corosync_conn)
  └─ InfluxDB: measurement "nics", tag host + instance (tên card)
       └─ Grafana dashboard
```

## Tính năng

- Bộ đếm lỗi/rớt gói của kernel: `rx_errors`, `rx_dropped`, `rx_crc_errors`, `rx_missed_errors`, `tx_dropped`, `tx_carrier_errors`, `collisions`…
- Counter của driver (`ethtool -S`): `port.rx_crc_errors`, `veb.rx_discards`, `port.tx_dropped_link_down`…
- Trạng thái link: `network_up`, `link_speed`, `link_speed_max` (phát hiện card 10G/25G đang chạy tốc độ thấp hơn).
- Chỉ số hệ thống: `udp_loss`, `udp_total`, `corosync_conn`.
- Script cài, kiểm tra, chẩn đoán, gỡ cho nhiều node qua SSH. Patch an toàn: kiểm tra `perl -c` trước khi ghi, có backup, chạy lại không bị chèn trùng.
- Dashboard Grafana mẫu, tự sinh đúng bucket/datasource cho từng cluster.

## Yêu cầu

- Proxmox VE 8.x/9.x, đã cấu hình **Datacenter → Metric Server** loại **InfluxDB** (InfluxDB 2.x, Flux).
- Grafana có datasource InfluxDB (Flux) trỏ tới bucket đó.
- Quyền root và SSH (key hoặc mật khẩu + `sshpass`) từ node chạy script tới các node.
- `ethtool` trên các node.

## Cấu trúc repo

```
monitor-grafana-proxmox-cluster-influxdb/
├── deploy/                          ← bộ cài, copy cả thư mục này lên node
│   ├── CustomNetworkMetrics.pm      ← module Perl thu thập số liệu
│   ├── deploy-monitor-nic-proxmox.sh← script install / check / diag / dashboard / uninstall
│   ├── nodes.txt                    ← danh sách IP node (điền IP của bạn)
│   └── dashboard-template.json      ← dashboard Grafana mẫu
└── docs/
    ├── Huong-Dan-Trien-Khai.md      ← hướng dẫn từng bước (bắt đầu ở đây)
    ├── Canh-Bao-Va-Xu-Ly-Su-Co.md   ← cảnh báo Grafana, đọc lỗi, xử lý sự cố, vận hành
    └── Cai-Dat-Thu-Cong.md          ← cách patch thủ công, giải thích nguyên lý
```

## Cài nhanh

Chạy trên node đầu tiên của cluster (root):

```bash
apt install -y git ethtool
git clone https://github.com/fixnhanh-linux/monitor-grafana-proxmox-cluster-influxdb.git /root/monitor-grafana-proxmox-cluster-influxdb
cd /root/monitor-grafana-proxmox-cluster-influxdb/deploy
chmod +x deploy-monitor-nic-proxmox.sh

# 1. Khai báo IP các node, mỗi dòng 1 IP
nano nodes.txt

# 2. Cài thử 1 node, kiểm tra output toàn [OK]
./deploy-monitor-nic-proxmox.sh install 10.0.0.11

# 3. Tạo dashboard đúng bucket của cluster rồi import vào Grafana
./deploy-monitor-nic-proxmox.sh dashboard

# 4. Cài cho cả cluster và kiểm tra
./deploy-monitor-nic-proxmox.sh install -f nodes.txt
./deploy-monitor-nic-proxmox.sh check   -f nodes.txt
```

Node không có Internet: tải `monitor-nic-proxmox.zip` ở mục **Releases**, `scp` lên node rồi giải nén. Chi tiết trong [docs/Huong-Dan-Trien-Khai.md](docs/Huong-Dan-Trien-Khai.md).

## Các lệnh

| Lệnh | Tác dụng |
|---|---|
| `install [-f nodes.txt \| ip...]` | Cài module, patch `InfluxDB.pm` (có backup), restart `pvestatd`, tự kiểm tra |
| `check [-f nodes.txt \| ip...]` | Kiểm tra module, patch, ethtool, pvestatd và in số liệu từng card |
| `diag [-f nodes.txt \| ip...]` | Chẩn đoán vì sao Grafana không có số liệu (cấu hình, log, kết nối, dữ liệu trong bucket) |
| `dashboard [bucket]` | Tạo `dashboard-<bucket>.json` từ template; có `GRAFANA_URL` + `GRAFANA_TOKEN` thì import luôn |
| `uninstall [-f nodes.txt \| ip...]` | Khôi phục `InfluxDB.pm` gốc, xóa module, restart `pvestatd` |

Không truyền node thì script dùng `nodes.txt` nằm cạnh script.

Biến môi trường: `SSH_USER` (mặc định `root`), `SSH_PASS` (cần `sshpass`), `GRAFANA_URL`, `GRAFANA_TOKEN`, `GRAFANA_DS`.

## Lưu ý quan trọng

- **Nâng cấp `pve-manager` sẽ ghi đè `InfluxDB.pm` và làm mất patch.** Sau mỗi lần `apt upgrade`, chạy lại `./deploy-monitor-nic-proxmox.sh install -f nodes.txt`.
- Script là file LF. Nếu copy qua Windows bị đổi sang CRLF (`$'\r': command not found`), chạy `sed -i 's/\r$//' *.sh *.pm`.
- Không commit token Grafana/InfluxDB hay IP thật vào repo.

## Tài liệu

1. [Hướng dẫn triển khai từng bước](docs/Huong-Dan-Trien-Khai.md)
2. [Cảnh báo, xử lý sự cố và vận hành](docs/Canh-Bao-Va-Xu-Ly-Su-Co.md)
3. [Cài đặt thủ công và nguyên lý](docs/Cai-Dat-Thu-Cong.md)
