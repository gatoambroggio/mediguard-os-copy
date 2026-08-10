#!/usr/bin/env python3
"""vpn.py - Gestion de VPN para ZetronPOC / MediGuard OS.

Cliente (saliente): NetworkManager (nmcli) con plugins openvpn/l2tp/pptp.
Servidor (entrante): OpenVPN (tls-crypt static), PPTP (pptpd), L2TP/IPsec (strongSwan + xl2tpd).

Toda operacion es best-effort: si falta un paquete, devuelve {error: ...} sin romper.
Requiere que el backend corra como root (systemctl / escritura en /etc)."""
import os, re, subprocess

VPN_NAME = re.compile(r'^[A-Za-z0-9_\-]+$')


def _run(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or ""), (r.stderr or "")
    except FileNotFoundError:
        return 127, "", "comando no encontrado: %s" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except Exception as e:
        return 1, "", str(e)


def _svc_active(name):
    rc, out, _ = _run(["systemctl", "is-active", name], timeout=5)
    return (out or "").strip() or "unknown"


def _svc_enabled(name):
    rc, out, _ = _run(["systemctl", "is-enabled", name], timeout=5)
    return (out or "").strip() == "enabled"


def _has_unit(name):
    rc, _, _ = _run(["systemctl", "cat", name], timeout=5)
    return rc == 0


def _swan_name():
    for n in ("strongswan-starter", "strongswan", "ipsec"):
        if _has_unit(n):
            return n
    return "strongswan-starter"


# ===================== ESTADO GENERAL =====================
def status():
    rc, out, err = _run(["nmcli", "-t", "-f", "STATE,CONNECTIVITY", "general", "status"], timeout=8)
    state, conn = "desconocido", "desconocido"
    if rc == 0 and out.strip():
        parts = out.strip().split(":")
        state = parts[0] if len(parts) > 0 else state
        conn = parts[1] if len(parts) > 1 else conn
    _, ipout, _ = _run(["bash", "-c", "curl -s --max-time 4 https://ifconfig.me 2>/dev/null || true"], timeout=8)
    return {"nm_state": state, "connectivity": conn, "external_ip": ipout.strip()}


# ===================== CLIENTE (SALIENTE) =====================
def list_clients():
    rc, out, err = _run(["nmcli", "-t", "-f", "NAME,TYPE,DEVICE", "connection", "show"], timeout=10)
    if rc != 0:
        return {"error": (err or "nmcli no disponible").strip()}
    rows = []
    for line in out.splitlines():
        parts = line.split(":")
        if len(parts) < 3:
            continue
        name, typ, dev = parts[0], parts[1], parts[2]
        if typ == "vpn" or "vpn" in typ.lower() or typ == "wireguard":
            rows.append({
                "name": name, "type": typ,
                "device": dev if dev != "--" else "",
                "state": "activa" if (dev and dev != "--") else "inactiva",
            })
    return rows


def create_client(d):
    name = (d.get("name") or "").strip()
    proto = (d.get("protocol") or "").strip().lower()
    gateway = (d.get("gateway") or "").strip()
    user = (d.get("user") or "").strip()
    password = (d.get("password") or "").strip()
    psk = (d.get("psk") or "").strip()
    ovpn = (d.get("ovpn_file") or "").strip()
    if not name or not VPN_NAME.match(name):
        return {"error": "nombre invalido (solo letras, numeros, _ -)"}
    if proto not in ("openvpn", "l2tp", "pptp"):
        return {"error": "protocolo invalido (openvpn/l2tp/pptp)"}
    if not gateway and not (proto == "openvpn" and ovpn):
        return {"error": "falta gateway/servidor"}
    _run(["nmcli", "connection", "delete", name], timeout=10)

    if proto == "openvpn":
        if ovpn and os.path.exists(ovpn):
            rc, out, err = _run(["nmcli", "connection", "import", "type", "openvpn", "file", ovpn], timeout=20)
            if rc == 0:
                base = os.path.splitext(os.path.basename(ovpn))[0]
                _run(["nmcli", "connection", "modify", base, "connection.id", name], timeout=10)
            return {"ok": rc == 0, "salida": out, "error": (err if rc else None)}
        rc, out, err = _run(["nmcli", "connection", "add", "type", "vpn", "ifname", "tun0",
                             "con-name", name, "vpn-type", "openvpn"], timeout=15)
        if rc == 0:
            data = "remote=%s,connection-type=tls" % gateway
            _run(["nmcli", "connection", "modify", name, "vpn.data", data], timeout=10)
            if password:
                _run(["nmcli", "connection", "modify", name, "vpn.secrets.password", password], timeout=10)
        return {"ok": rc == 0, "salida": out, "error": (err if rc else None)}

    if proto == "l2tp":
        rc, out, err = _run(["nmcli", "connection", "add", "type", "vpn", "ifname", "ppp0",
                             "con-name", name, "vpn-type", "l2tp"], timeout=15)
        if rc == 0:
            data = "gateway=%s,user=%s,password-flags=0" % (gateway, user)
            _run(["nmcli", "connection", "modify", name, "vpn.data", data], timeout=10)
            if psk:
                _run(["nmcli", "connection", "modify", name, "vpn.secrets.ipsec-psk", psk], timeout=10)
            if password:
                _run(["nmcli", "connection", "modify", name, "vpn.secrets.password", password], timeout=10)
        return {"ok": rc == 0, "salida": out, "error": (err if rc else None)}

    if proto == "pptp":
        rc, out, err = _run(["nmcli", "connection", "add", "type", "vpn", "ifname", "ppp0",
                             "con-name", name, "vpn-type", "pptp"], timeout=15)
        if rc == 0:
            data = "gateway=%s,user=%s,password-flags=0" % (gateway, user)
            _run(["nmcli", "connection", "modify", name, "vpn.data", data], timeout=10)
            if password:
                _run(["nmcli", "connection", "modify", name, "vpn.secrets.password", password], timeout=10)
        return {"ok": rc == 0, "salida": out, "error": (err if rc else None)}


def up(name):
    if not name or not VPN_NAME.match(name):
        return {"error": "nombre invalido"}
    rc, out, err = _run(["nmcli", "connection", "up", name], timeout=60)
    return {"ok": rc == 0, "salida": out, "error": (err if rc else None)}


def down(name):
    if not name or not VPN_NAME.match(name):
        return {"error": "nombre invalido"}
    rc, out, err = _run(["nmcli", "connection", "down", name], timeout=30)
    return {"ok": rc == 0, "salida": out, "error": (err if rc else None)}


def delete_client(name):
    if not name or not VPN_NAME.match(name):
        return {"error": "nombre invalido"}
    rc, out, err = _run(["nmcli", "connection", "delete", name], timeout=15)
    return {"ok": rc == 0, "salida": out, "error": (err if rc else None)}


# ===================== SERVIDOR (ENTRANTE) =====================
def server_status():
    swan = _swan_name()
    return {
        "openvpn": {"active": _svc_active("openvpn-server@server"), "enabled": _svc_enabled("openvpn-server@server")},
        "pptp": {"active": _svc_active("pptpd"), "enabled": _svc_enabled("pptpd")},
        "l2tp_ipsec": {"active": _svc_active(swan), "enabled": _svc_enabled(swan), "service": swan},
        "l2tp_xl2tpd": {"active": _svc_active("xl2tpd"), "enabled": _svc_enabled("xl2tpd")},
        "listening": _listening_ports(),
    }


def _listening_ports():
    rc, out, _ = _run(["bash", "-c", "ss -tlnp 2>/dev/null | grep -E ':(1194|1723|500|4500|1701)' || true"], timeout=6)
    return out.strip()


def server_apply(d):
    proto = (d.get("protocol") or "").strip().lower()
    if proto == "openvpn":
        return _openvpn_server(d)
    if proto == "pptp":
        return _pptp_server(d)
    if proto == "l2tp":
        return _l2tp_server(d)
    return {"error": "protocolo invalido (openvpn/pptp/l2tp)"}


def _openvpn_server(d):
    try:
        port = int(d.get("port", 1194) or 1194)
    except (ValueError, TypeError):
        port = 1194
    proto = (d.get("proto") or "udp").lower()
    net = (d.get("network") or "10.8.0.0").strip()
    mask = (d.get("mask") or "255.255.255.0").strip()
    key_dir = "/etc/openvpn/server/keys"
    os.makedirs(key_dir, exist_ok=True)
    key_path = os.path.join(key_dir, "static.key")
    if not os.path.exists(key_path):
        rc, _, err = _run(["openvpn", "--genkey", "--secret", key_path], timeout=15)
        if rc != 0:
            return {"error": "no se pudo generar clave (openvpn instalado?): %s" % err}
    conf = ("port %d\nproto %s\ndev tun\nsecret %s\nserver %s %s\n"
            "keepalive 10 120\npersist-key\npersist-tun\n"
            "status /var/log/openvpn-status.log\nverb 3\n") % (port, proto, key_path, net, mask)
    path = "/etc/openvpn/server/server.conf"
    try:
        with open(path, "w") as f:
            f.write(conf)
    except PermissionError as e:
        return {"error": "sin permisos para escribir %s (¿backend como root?): %s" % (path, e)}
    _run(["systemctl", "enable", "openvpn-server@server"], timeout=10)
    rc, out, err = _run(["systemctl", "restart", "openvpn-server@server"], timeout=20)
    return {"ok": rc == 0, "conf": path, "key": key_path, "error": (err if rc else None)}


def _pptp_server(d):
    localip = (d.get("local_ip") or "10.0.0.1").strip()
    remoteip = (d.get("remote_ip") or "10.0.0.100-200").strip()
    user = (d.get("user") or "vpn").strip() or "vpn"
    password = (d.get("password") or "vpn").strip() or "vpn"
    try:
        with open("/etc/pptpd.conf", "w") as f:
            f.write("option /etc/ppp/pptpd-options\nlogwtmp\nlocalip %s\nremoteip %s\n" % (localip, remoteip))
        with open("/etc/ppp/pptpd-options", "w") as f:
            f.write("require-mschap-v2\nms-dns 8.8.8.8\nms-dns 8.8.4.4\nproxyarp\nlock\nnobsdcomp\nnovj\nnovjccomp\nnologfd\n")
        with open("/etc/ppp/chap-secrets", "w") as f:
            f.write("%s pptpd %s *\n" % (user, password))
    except PermissionError as e:
        return {"error": "sin permisos (¿backend como root?): %s" % e}
    _run(["systemctl", "enable", "pptpd"], timeout=10)
    rc, out, err = _run(["systemctl", "restart", "pptpd"], timeout=20)
    return {"ok": rc == 0, "user": user, "error": (err if rc else None)}


def _l2tp_server(d):
    psk = (d.get("psk") or "zetronpoc").strip() or "zetronpoc"
    user = (d.get("user") or "vpn").strip() or "vpn"
    password = (d.get("password") or "vpn").strip() or "vpn"
    localip = (d.get("local_ip") or "10.0.1.1").strip()
    remoteip = (d.get("remote_ip") or "10.0.1.100-10.0.1.200").strip()
    ipsec = ("config setup\n    uniqueids=no\n\n"
             "conn L2TP\n    keyexchange=ikev1\n    authby=secret\n    auto=add\n"
             "    keyingtries=3\n    ike=aes256-sha1-modp1024\n    esp=aes256-sha1\n"
             "    left=%%defaultroute\n    leftprotoport=17/1701\n"
             "    right=%%any\n    rightprotoport=17/%%any\n    rightsubnet=0.0.0.0/0\n"
             "    dpdaction=clear\n")
    try:
        with open("/etc/ipsec.conf", "w") as f:
            f.write(ipsec)
        with open("/etc/ipsec.secrets", "w") as f:
            f.write(': PSK "%s"\n' % psk)
        os.makedirs("/etc/xl2tpd", exist_ok=True)
        with open("/etc/xl2tpd/xl2tpd.conf", "w") as f:
            f.write("[global]\nipsec saref = yes\n[lns default]\nip range = %s\nlocal ip = %s\n"
                    "require authentication = yes\nppp debug = no\npppoptfile = /etc/ppp/options.xl2tpd\n" % (remoteip, localip))
        with open("/etc/ppp/options.xl2tpd", "w") as f:
            f.write("require-mschap-v2\nms-dns 8.8.8.8\nms-dns 8.8.4.4\nproxyarp\nlock\nnovj\nnovjccomp\nnologfd\n")
        with open("/etc/ppp/chap-secrets", "w") as f:
            f.write("%s * %s *\n" % (user, password))
    except PermissionError as e:
        return {"error": "sin permisos (¿backend como root?): %s" % e}
    swan = _swan_name()
    _run(["systemctl", "enable", swan], timeout=10)
    rc1, _, e1 = _run(["systemctl", "restart", swan], timeout=20)
    _run(["systemctl", "enable", "xl2tpd"], timeout=10)
    rc2, _, e2 = _run(["systemctl", "restart", "xl2tpd"], timeout=20)
    return {"ok": rc1 == 0 and rc2 == 0, "strongswan": swan, "user": user,
            "error": ((e1 or e2) if (rc1 or rc2) else None)}


def server_stop(proto):
    proto = (proto or "").lower()
    if proto == "openvpn":
        rc, out, err = _run(["systemctl", "stop", "openvpn-server@server"], timeout=20)
        return {"ok": rc == 0, "error": (err if rc else None)}
    if proto == "pptp":
        rc, out, err = _run(["systemctl", "stop", "pptpd"], timeout=20)
        return {"ok": rc == 0, "error": (err if rc else None)}
    if proto == "l2tp":
        _run(["systemctl", "stop", _swan_name()], timeout=20)
        rc, out, err = _run(["systemctl", "stop", "xl2tpd"], timeout=20)
        return {"ok": rc == 0, "error": (err if rc else None)}
    return {"error": "protocolo invalido"}


def logs(kind="server", lines=80):
    try:
        lines = int(lines)
    except (ValueError, TypeError):
        lines = 80
    svc_map = {
        "openvpn": "openvpn-server@server",
        "pptp": "pptpd",
        "l2tp": _swan_name(),
        "xl2tpd": "xl2tpd",
        "nm": "NetworkManager",
    }
    svc = svc_map.get(kind)
    if not svc:
        return {"error": "tipo invalido (openvpn/pptp/l2tp/xl2tpd/nm)"}
    rc, out, err = _run(["journalctl", "-u", svc, "-n", str(lines), "--no-pager"], timeout=10)
    return {"lineas": (out or "").splitlines()[-lines:], "service": svc, "error": (err if rc else None)}