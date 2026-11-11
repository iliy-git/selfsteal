#!/usr/bin/env python3
"""
configure_xui.py - Auto-configure 3x-ui / Xray for SelfSteal VLESS REALITY
"""
import sys
import os
import argparse
import sqlite3
import json
import uuid
import secrets
import shutil
import time
import re
import subprocess
import urllib.request

def get_public_ip():
    """Detect server public IPv4."""
    for url in ("https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com"):
        try:
            with urllib.request.urlopen(url, timeout=4) as resp:
                ip = resp.read().decode().strip()
                if re.match(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$", ip):
                    return ip
        except Exception:
            continue
    return "127.0.0.1"

def generate_x25519():
    """Generate x25519 keypair for REALITY."""
    # 1. Try xray binary if available
    xray_bins = [
        shutil.which("xray"),
        "/usr/local/x-ui/bin/xray-linux-amd64",
        "/usr/local/bin/xray",
        "/usr/bin/xray",
    ]
    for bin_path in xray_bins:
        if bin_path and os.path.isfile(bin_path) and os.access(bin_path, os.X_OK):
            try:
                out = subprocess.check_output([bin_path, "x25519"], text=True, timeout=5)
                priv = re.search(r"(?:Private\s*key|PrivateKey):\s*(\S+)", out, re.I)
                pub = re.search(r"(?:Public\s*key|Password \(PublicKey\)|PublicKey):\s*(\S+)", out, re.I)
                if priv and pub:
                    return priv.group(1), pub.group(1)
            except Exception:
                pass

    # 2. Try python cryptography module
    try:
        import base64
        from cryptography.hazmat.primitives.asymmetric import x25519
        from cryptography.hazmat.primitives import serialization

        priv = x25519.X25519PrivateKey.generate()
        pub = priv.public_key()
        priv_bytes = priv.private_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PrivateFormat.Raw,
            encryption_algorithm=serialization.NoEncryption(),
        )
        pub_bytes = pub.public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
        priv_b64 = base64.urlsafe_b64encode(priv_bytes).decode().rstrip("=")
        pub_b64 = base64.urlsafe_b64encode(pub_bytes).decode().rstrip("=")
        return priv_b64, pub_b64
    except Exception:
        pass

    raise RuntimeError("Failed to generate x25519 keypair: neither xray nor python cryptography available")

def find_free_port(cur, start=44300):
    cur.execute("SELECT port FROM inbounds")
    used = {r[0] for r in cur.fetchall() if r[0]}
    port = start
    while port in used:
        port += 1
    return port

def main():
    parser = argparse.ArgumentParser(description="Configure 3x-ui for SelfSteal VLESS REALITY")
    parser.add_argument("--db", default="/etc/x-ui/x-ui.db", help="Path to 3x-ui SQLite database")
    parser.add_argument("--domain", required=True, help="Domain for SelfSteal SNI")
    parser.add_argument("--dest", default="127.0.0.1:8443", help="Local destination for REALITY fallback")
    parser.add_argument("--port", type=int, default=443, help="External listening port (default: 443)")
    parser.add_argument("--ip", default=None, help="Server public IP")
    parser.add_argument("--json", action="store_true", help="Output JSON result only")
    args = parser.parse_args()

    db_path = os.path.abspath(args.db)
    if not os.path.isfile(db_path):
        if args.json:
            print(json.dumps({"status": "error", "message": f"Database file not found: {db_path}"}))
        else:
            print(f"[ERROR] База данных 3x-ui не найдена по пути: {db_path}", file=sys.stderr)
        sys.exit(2)

    domain = args.domain.strip()
    dest = args.dest.strip()
    target_port = args.port
    server_ip = args.ip if args.ip else get_public_ip()

    # Backup database
    backup_path = f"{db_path}.bak_{int(time.time())}"
    shutil.copy2(db_path, backup_path)

    con = sqlite3.connect(db_path)
    cur = con.cursor()

    # Check table columns in inbounds
    cur.execute("PRAGMA table_info(inbounds)")
    inbound_cols = {c[1]: c[2] for c in cur.fetchall()}

    # Check for tables
    cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
    existing_tables = {r[0] for r in cur.fetchall()}

    # Fetch all inbounds
    cur.execute("SELECT id, port, protocol, settings, stream_settings, tag, enable FROM inbounds")
    rows = cur.fetchall()

    reality_inbound = None
    inbound_on_443 = None

    for r in rows:
        iid, iport, iproto, isettings, istream, itag, ienable = r
        st = {}
        if istream:
            try:
                st = json.loads(istream)
            except Exception:
                pass

        if iproto == "vless" and st.get("security") == "reality":
            if reality_inbound is None:
                reality_inbound = r
        if iport == target_port:
            inbound_on_443 = r

    # If another inbound occupies port 443, move it
    if inbound_on_443 and (reality_inbound is None or inbound_on_443[0] != reality_inbound[0]):
        free_port = find_free_port(cur)
        other_id = inbound_on_443[0]
        cur.execute("UPDATE inbounds SET port = ? WHERE id = ?", (free_port, other_id))
        if not args.json:
            print(f"[INFO] Порт {target_port} был занят инбаундом ID {other_id}. Он перемещен на свободный порт {free_port}.")

    action = "updated"
    if reality_inbound:
        iid, iport, iproto, isettings_raw, istream_raw, itag, ienable = reality_inbound
        st = json.loads(istream_raw) if istream_raw else {}
        st["security"] = "reality"
        rs = st.setdefault("realitySettings", {})
        rs["target"] = dest
        rs["serverNames"] = [domain]
        if "settings" in rs and isinstance(rs["settings"], dict):
            rs["settings"]["serverName"] = domain
            pub_key = rs["settings"].get("publicKey", "")
            fp = rs["settings"].get("fingerprint", "chrome")
            spx = rs["settings"].get("spiderX", "/")
        else:
            pub_key = ""
            fp = "chrome"
            spx = "/"

        short_ids = rs.get("shortIds", [])
        sid = short_ids[0] if short_ids else ""

        # Parse settings for client
        settings = json.loads(isettings_raw) if isettings_raw else {}
        clients = settings.setdefault("clients", [])
        if not clients:
            client_uuid = str(uuid.uuid4())
            clients.append({
                "id": client_uuid,
                "email": f"selfsteal@{domain}",
                "enable": True,
                "expiryTime": 0,
                "totalGB": 0,
                "reset": 0,
            })
        else:
            client_uuid = clients[0].get("id") or clients[0].get("uuid") or str(uuid.uuid4())
            clients[0]["id"] = client_uuid

        tag = f"in-{target_port}-tcp"
        cur.execute("""
            UPDATE inbounds
            SET port = ?, enable = 1, tag = ?, stream_settings = ?, settings = ?
            WHERE id = ?
        """, (target_port, tag, json.dumps(st), json.dumps(settings), iid))
        target_inbound_id = iid
    else:
        action = "created"
        priv_key, pub_key = generate_x25519()
        sid = secrets.token_hex(4)
        spx = "/"
        fp = "chrome"
        client_uuid = str(uuid.uuid4())
        client_sub_id = secrets.token_hex(8)

        st = {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": False,
                "xver": 0,
                "target": dest,
                "serverNames": [domain],
                "privateKey": priv_key,
                "minClientVer": "",
                "maxClientVer": "",
                "maxTimediff": 0,
                "shortIds": [sid],
                "settings": {
                    "publicKey": pub_key,
                    "fingerprint": fp,
                    "serverName": domain,
                    "spiderX": spx,
                },
            },
            "tcpSettings": {
                "acceptProxyProtocol": False,
                "header": {"type": "none"},
            },
        }

        settings = {
            "clients": [{
                "id": client_uuid,
                "email": f"selfsteal@{domain}",
                "enable": True,
                "expiryTime": 0,
                "totalGB": 0,
                "reset": 0,
                "subId": client_sub_id,
            }],
            "decryption": "none",
            "fallbacks": [],
        }

        new_inbound = {
            "user_id": 1,
            "up": 0,
            "down": 0,
            "total": 0,
            "remark": f"SelfSteal-{domain}",
            "enable": 1,
            "expiry_time": 0,
            "listen": "",
            "port": target_port,
            "protocol": "vless",
            "settings": json.dumps(settings),
            "stream_settings": json.dumps(st),
            "tag": f"in-{target_port}-tcp",
            "sniffing": '{"enabled":false}',
        }

        cols = [k for k in new_inbound.keys() if k in inbound_cols]
        placeholders = ",".join(["?"] * len(cols))
        col_names = ",".join(cols)
        values = [new_inbound[k] for k in cols]

        cur.execute(f"INSERT INTO inbounds ({col_names}) VALUES ({placeholders})", values)
        target_inbound_id = cur.lastrowid

        # If clients table exists, insert client
        if "clients" in existing_tables:
            cur.execute("PRAGMA table_info(clients)")
            client_cols = {c[1]: c[2] for c in cur.fetchall()}
            now_ms = int(time.time() * 1000)
            client_data = {
                "email": f"selfsteal@{domain}",
                "sub_id": client_sub_id,
                "uuid": client_uuid,
                "enable": 1,
                "created_at": now_ms,
                "updated_at": now_ms,
            }
            c_cols = [k for k in client_data.keys() if k in client_cols]
            c_placeholders = ",".join(["?"] * len(c_cols))
            c_names = ",".join(c_cols)
            cur.execute(f"INSERT INTO clients ({c_names}) VALUES ({c_placeholders})", [client_data[k] for k in c_cols])
            new_client_id = cur.lastrowid

            if "client_inbounds" in existing_tables:
                cur.execute("INSERT OR REPLACE INTO client_inbounds (client_id, inbound_id, flow_override, created_at) VALUES (?, ?, '', ?)",
                            (new_client_id, target_inbound_id, now_ms))

    con.commit()
    con.close()

    spx_encoded = urllib.request.quote(spx, safe="")
    vless_link = (
        f"vless://{client_uuid}@{server_ip}:{target_port}?"
        f"type=tcp&security=reality&pbk={pub_key}&fp={fp}&sni={domain}&sid={sid}&spx={spx_encoded}#SelfSteal-{domain}"
    )

    result = {
        "status": "success",
        "action": action,
        "backup": backup_path,
        "inbound_id": target_inbound_id,
        "domain": domain,
        "dest": dest,
        "port": target_port,
        "server_ip": server_ip,
        "client_uuid": client_uuid,
        "public_key": pub_key,
        "short_id": sid,
        "vless_link": vless_link,
    }

    if args.json:
        print(json.dumps(result))
    else:
        print(f"[✓] 3x-ui успешно настроен! Действие: {action} (Инбаунд ID: {target_inbound_id})")
        print(f"[✓] Входящий порт: {target_port} | Fallback Target: {dest} | SNI: {domain}")
        print(f"[✓] VLESS REALITY Link:\n{vless_link}")

if __name__ == "__main__":
    main()
