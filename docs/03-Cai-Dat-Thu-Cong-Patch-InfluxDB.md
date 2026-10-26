---
title: "Hướng Dẫn Thu Thập Advanced Network Metrics Cho Proxmox Bằng Native InfluxDB"
description: "Cách can thiệp vào lõi Proxmox để đẩy trực tiếp thông số Hardware Drop, UDP Loss, trạng thái UP/DOWN của mọi card mạng (10Gbps) lên InfluxDB mà không cần cài thêm công cụ."
tags: ["Proxmox", "InfluxDB", "Grafana", "Monitoring", "Network"]
---

# Hướng Dẫn Tích Hợp Advanced Network Metrics Vào Proxmox (Native InfluxDB)

> **Lưu ý:** Đây là cách làm thủ công để hiểu nguyên lý. Đoạn module bên dưới là bản rút gọn; bản đầy đủ và mới nhất là [`deploy/CustomNetworkMetrics.pm`](../deploy/CustomNetworkMetrics.pm). Khi triển khai thật, nên dùng script theo [Hướng dẫn triển khai](01-Huong-Dan-Trien-Khai-Monitor-NIC-Proxmox.md). Về timeout, nên sửa trong **Datacenter → Metric Server → Edit** thay vì tự nối dòng vào `/etc/pve/status.cfg`.

Mặc định, Proxmox tích hợp sẵn khả năng xuất (export) metric hệ thống ra InfluxDB thông qua tiến trình `pvestatd`. Tuy nhiên, các thông số mặc định chỉ dừng lại ở băng thông (TX/RX) mà **thiếu hụt** các chỉ số mạng quan trọng ở mức thấp (Low-level Metrics) như: số gói tin bị rớt ở card vật lý (Hardware Drop), gói tin UDP bị lỗi, và trạng thái cắm cáp của các card mạng 10Gbps/40Gbps.

Bài viết này hướng dẫn cách can thiệp vào plugin InfluxDB gốc của Proxmox, giúp thu thập và gửi các dữ liệu này một cách **100% Native**, không tốn thêm tài nguyên chạy các bash script vòng lặp hay công cụ như Telegraf.

---

## Mục Tiêu Thu Thập

Chúng ta sẽ bổ sung các chỉ số sau, được nhúng trực tiếp vào các Data Measurement gốc của Proxmox:

1. **System Metrics (Nhúng vào Measurement `system`):**
   - `udp_loss`: Số lượng gói tin UDP bị lỗi/rớt (InErrors).
   - `udp_total`: Tổng số gói tin UDP hệ thống đã nhận (InDatagrams).
   - `corosync_conn`: Số socket UDP Corosync đang mở (cổng 5404/5405), chỉ để tham khảo.
   - `corosync_links`, `corosync_links_up`, `corosync_link<N>_{peers,connected,up,iface}`: trạng thái từng link Corosync (link0, link1…) đọc từ `corosync-cfgtool -s`. Có trong `deploy/CustomNetworkMetrics.pm`; nếu cài tay theo tài liệu này, hãy copy module từ thư mục `deploy/` thay cho đoạn code mẫu bên dưới để có đủ các field này.
   
2. **Network Card Metrics (Nhúng vào Measurement `nics`):**
   - Quét tự động **toàn bộ** card mạng vật lý và ảo (`eno1`, `eno3f0`, `vmbr0`...).
   - `hardware_drop`: Số gói tin rớt tại tầng phần cứng (RX Dropped).
   - `network_up`: Trạng thái hoạt động của card (1 = UP/Sáng đèn, 0 = DOWN/Rút cáp).
   - **Lỗi/rớt gói (tương đương `ip -s link`):** `rx_errors`, `rx_missed_errors`, `rx_length_errors`, `rx_crc_errors`, `rx_over_errors`, `rx_fifo_errors`, `rx_frame_errors`, `tx_errors`, `tx_dropped`, `tx_carrier_errors`, `tx_fifo_errors`, `tx_aborted_errors`, `tx_window_errors`, `tx_heartbeat_errors`, `collisions`.
   - **Lưu lượng:** `rx_bytes`, `rx_packets`, `tx_bytes`, `tx_packets`, `multicast`.
   - **Link:** `carrier`, `carrier_changes`, `carrier_up_count`, `carrier_down_count`.
   - **Counter phần cứng (`ethtool -S`, chỉ card vật lý):** nhóm `veb_*` và `port_*`, ví dụ `port_rx_crc_errors`, `port_rx_length_errors`, `port_tx_timeout`, `port_tx_dropped_link_down`, `veb_rx_discards`, `veb_tx_discards`.

---

## Hướng Dẫn Cấu Hình Chi Tiết

> **Cảnh Báo An Toàn:** 
> Hãy luôn sao lưu file cấu hình gốc trước khi tiến hành chỉnh sửa bằng lệnh sau:
> ```bash
> cp /usr/share/perl5/PVE/Status/InfluxDB.pm /usr/share/perl5/PVE/Status/InfluxDB.pm.bak
> ```

### Bước 1: Tạo Module Thu Thập Dữ Liệu Chuyên Biệt
Để giữ cho mã nguồn của Proxmox sạch sẽ và dễ bảo trì khi nâng cấp, chúng ta sẽ tạo một Module Perl riêng biệt để xử lý logic lấy dữ liệu.

Tạo file mới tại đường dẫn: `/usr/share/perl5/PVE/CustomNetworkMetrics.pm`

**Nội dung file:**
```perl
package PVE::CustomNetworkMetrics;

use strict;
use warnings;

# Hàm này sẽ được gọi từ PVE::Status::InfluxDB
sub get_metrics {

    my $result = {
        global => {},
        nics => {}
    };

    eval {
        # 1. Thu thap du lieu he thong (UDP/Corosync) - doc truc tiep /proc, khong qua shell
        my ($udp_total, $udp_loss) = (0, 0);
        if (open(my $snmp, "<", "/proc/net/snmp")) {
            my @u = split(/\s+/, (grep { /^Udp: \d/ } <$snmp>)[0] // "");
            close($snmp);
            ($udp_total, $udp_loss) = ($u[1] // 0, $u[3] // 0);
        }
        my $corosync = `ss -una | grep -E '5404|5405' | wc -l`; chomp($corosync);

        $result->{global}->{udp_loss} = $udp_loss + 0;
        $result->{global}->{udp_total} = $udp_total + 0;
        $result->{global}->{corosync_conn} = $corosync + 0;

        my $rd = sub {
            my ($f) = @_;
            open(my $h, "<", $f) or return undef;
            my $v = <$h>; close($h);
            return undef unless defined $v;
            chomp($v); return $v;
        };

        # 2. Quet cac card mang
        foreach my $iface (glob("/sys/class/net/*")) {
            $iface =~ s#.*/##;
            next if $iface eq 'lo';
            my $nic = ($result->{nics}->{$iface} = {});
            my $base = "/sys/class/net/$iface";

            # 2a. Trang thai UP/DOWN + carrier
            my $operstate = $rd->("$base/operstate");
            if (defined($operstate) && $operstate ne '') {
                $nic->{network_up} = ($operstate eq 'up' || $operstate eq 'unknown') ? 1 : 0;
            }
            foreach my $f (qw(carrier carrier_changes carrier_up_count carrier_down_count)) {
                my $v = $rd->("$base/$f");
                $nic->{$f} = $v + 0 if defined($v) && $v =~ /^\d+$/;
            }

            # 2b. Toan bo counter cua "ip -s link" (kernel statistics)
            #     rx_dropped giu ten cu "hardware_drop" de khong vo dashboard
            foreach my $f (qw(
                rx_bytes rx_packets rx_errors rx_dropped rx_missed_errors
                rx_length_errors rx_crc_errors rx_over_errors rx_fifo_errors rx_frame_errors
                tx_bytes tx_packets tx_errors tx_dropped tx_carrier_errors
                tx_fifo_errors tx_aborted_errors tx_window_errors tx_heartbeat_errors
                collisions multicast)) {
                my $v = $rd->("$base/statistics/$f");
                next unless defined($v) && $v =~ /^\d+$/;
                my $name = ($f eq 'rx_dropped') ? 'hardware_drop' : $f;
                $nic->{$name} = $v + 0;
            }

            # 2c. Counter phan cung cua "ethtool -S" (chi card vat ly, chi lay nhom veb.* va port.*
            #     vi cac counter con lai da co o 2b). veb.rx_discards -> veb_rx_discards
            next unless -e "$base/device";
            if (open(my $et, "-|", "ethtool -S $iface 2>/dev/null")) {
                while (my $line = <$et>) {
                    next unless $line =~ /^\s*((?:veb|port)\.[\w.]+):\s*(\d+)\s*$/;
                    (my $k = $1) =~ s/\./_/g;
                    $nic->{$k} = $2 + 0;
                }
                close($et);
            }
        }
    };
    if (my $err = $@) {
        warn "Loi khi thu thap advanced network metrics: $err\n";
    }

    return $result;
}

1;
```

### Bước 2: Nhúng Logic Vào Plugin InfluxDB Gốc
Tiếp theo, chúng ta sẽ hướng dẫn hệ thống gọi module vừa tạo và nhúng dữ liệu vào luồng đẩy lên InfluxDB.

Mở file mã nguồn lõi: `/usr/share/perl5/PVE/Status/InfluxDB.pm`

**1. Khai báo thư viện (Khoảng dòng 16):**
```perl
use PVE::Status::Plugin;
use PVE::CustomNetworkMetrics; # Thêm dòng này
use base('PVE::Status::Plugin');
```

**2. Gắn dữ liệu vào Payload (Khoảng dòng 104):**
Tìm hàm `sub update_node_status`. Chèn khối lệnh sau vào **ngay bên trên** dòng `build_influxdb_payload(...)`:

```perl
    # --- BẮT ĐẦU BLOCK NHÚNG DỮ LIỆU MẠNG NÂNG CAO ---
    my $extra_metrics = PVE::CustomNetworkMetrics::get_metrics();
    if ($extra_metrics) {
        # 1. Bơm số liệu hệ thống vào measurement "system"
        if ($extra_metrics->{global}) {
            foreach my $k (keys %{$extra_metrics->{global}}) {
                $data->{$k} = $extra_metrics->{global}->{$k};
            }
        }
        
        # 2. Bơm số liệu từng card vào measurement "nics", tự động chia tag (instance)
        if ($extra_metrics->{nics} && $data->{nics}) {
            foreach my $nic (keys %{$extra_metrics->{nics}}) {
                foreach my $k (keys %{$extra_metrics->{nics}->{$nic}}) {
                    $data->{nics}->{$nic}->{$k} = $extra_metrics->{nics}->{$nic}->{$k};
                }
            }
        }
    }
    # --- KẾT THÚC BLOCK NHÚNG DỮ LIỆU ---
```

### Bước 3: Tối Ưu Timeout Tránh Nghẽn Mạng (Quan Trọng)
Do payload gửi sang InfluxDB giờ đây đã mang thêm dữ liệu từ toàn bộ các card mạng, tiến trình `pvestatd` có thể gặp lỗi `500 Can't connect (Connection timed out)` do cấu hình timeout mặc định của Proxmox quá ngắn (1 giây).

Mở file cấu hình InfluxDB: `/etc/pve/status.cfg`
Thêm thông số `timeout 30` vào cuối khối cấu hình của máy chủ InfluxDB:

```text
influxdb: proxmox-cluster-deco
    port 8086
    server <IP-InfluxDB>
    bucket proxmox-cluster-deco
    influxdbproto http
    organization my-org
    timeout 30
```

---

## Khởi Động & Kiểm Tra Kết Quả

Áp dụng toàn bộ cài đặt bằng cách khởi động lại service thu thập:
```bash
systemctl restart pvestatd
```

### 1. Test Dữ Liệu Nóng Bằng Terminal
Nếu muốn kiểm tra xem các lệnh lấy số liệu có chạy đúng trên phần cứng máy chủ không, bạn hãy copy dán khối lệnh Perl sau vào Terminal. Lệnh này giả lập y hệt cách Proxmox sẽ gọi:

```bash
perl -e '
my $udp_loss = `awk "/Udp:/ {print \\\$4}" /proc/net/snmp | tail -n 1`; chomp($udp_loss);
my $udp_total = `awk "/Udp:/ {print \\\$2}" /proc/net/snmp | tail -n 1`; chomp($udp_total);
my $corosync = `ss -una | grep -E "5404|5405" | wc -l`; chomp($corosync);
print "=== DU LIEU THU THAP DUOC ===\n";
print "UDP Loss: " . ($udp_loss + 0) . "\n";
print "UDP Total: " . ($udp_total + 0) . "\n";
print "Corosync Conns: " . ($corosync + 0) . "\n";
foreach my $iface (glob("/sys/class/net/*")) {
    $iface =~ s#.*/##;
    next if $iface eq "lo";
    my $drop = `cat /sys/class/net/$iface/statistics/rx_dropped 2>/dev/null`; chomp($drop);
    my $operstate = `cat /sys/class/net/$iface/operstate 2>/dev/null`; chomp($operstate);
    my $is_up = ($operstate eq "up" || $operstate eq "unknown") ? 1 : 0;
    if ($drop =~ /^\d+$/) {
        print "HW Drop ($iface): " . ($drop + 0) . " | Trang thai: " . ($is_up ? "UP (1)" : "DOWN (0)") . "\n";
    }
}
print "=============================\n";
'
```

### 2. Xem Số Liệu Trên InfluxDB & Grafana
Truy cập InfluxDB Data Explorer để xác minh dữ liệu đã vào đúng kiến trúc:

- **Hardware Drop & Link State:**
  - `_measurement` = **`nics`**
  - Lọc theo tag `instance` = **`eno3f0`** (hoặc tên card mạng tương ứng)
  - Chọn field `hardware_drop`, `network_up`, `rx_errors`, `rx_crc_errors`, `tx_errors`, `port_rx_crc_errors`, `veb_rx_discards`...
- **System UDP & Corosync:**
  - `_measurement` = **`system`**
  - Chọn field `udp_loss`, `udp_total`, `corosync_conn`.

---
*Bây giờ bạn đã sẵn sàng xây dựng các biểu đồ cảnh báo (Alert) mạnh mẽ trên Grafana cho hệ thống Proxmox Cluster của mình!*
