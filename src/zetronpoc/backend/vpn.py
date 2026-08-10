#!/usr/bin/env python3
"""vpn.py - Gestion de VPN para ZetronPOC / MediGuard OS.

Cliente (saliente):
  - OpenVPN: systemd nativo (zetronpoc-openvpn-<name>.service), sin NetworkManager.
  - WireGuard: systemd nativo (wg-quick@<name>.service).
  - L2TP/PPTP: NetworkManager via keyfile en /etc/NetworkManager/system-connections
    (los secretos se guardan en [vpn-secrets] para que la activacion no pida --ask).

Servidor (entrante):
  - OpenVPN (tls-crypt static), PPTP (pptpd), L2TP/IPsec (strongSwan + xl2tpd),
    WireGuard (wg-quick@wg0).

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


# ===================== CLIENTE OPENVPN (NATIVO) =====================
_OVPN_DIR = "/etc/openvpn/client"
_OVPN_UNIT = "zetronpoc-openvpn-%s.service"


def _ovpn_conf_path(name):
    return os.path.join(_OVPN_DIR, name + ".conf")


def _ovpn_auth_path(name):
    return os.path.join(_OVPN_DIR, name + ".auth")


def _ovpn_unit(name):
    return _OVPN_UNIT % name


def _has_ovpn_unit(name):
    rc, _, _ = _run(["systemctl", "cat", _ovpn_unit(name)], timeout=5)
    return rc == 0


def _write_ovpn_unit(name):
    unit = _ovpn_unit(name)
    conf = _ovpn_conf_path(name)
    auth = _ovpn_auth_path(name)
    exec_args = "/usr/sbin/openvpn --config %s" % conf
    if os.path.exists(auth):
        exec_args += " --auth-user-pass %s" % auth
    body = (
        "[Unit]\n"
        "Description=OpenVPN client %s (ZetronPOC)\n"
        "After=network-online.target\n"
        "Wants=network-online.target\n\n"
        "[Service]\n"
        "Type=simple\n"
        "ExecStart=%s\n"
        "Restart=on-failure\n"
        "RestartSec=5\n\n"
        "[Install]\n"
        "WantedBy=multi-user.target\n"
    ) % (name, exec_args)
    path = "/etc/systemd/system/%s" % unit
    with open(path, "w") as f:
        f.write(body)
    _run(["systemctl", "daemon-reload"], timeout=10)
    _run(["systemctl", "enable", unit], timeout=10)


def _ovpn_clients():
    rc, out, _ = _run(["systemctl", "list-unit-files", "zetronpoc-openvpn-*.service", "--no-legend"], timeout=8)
    rows = []
    for line in (out or "").splitlines():
        parts = line.split()
        if len(parts) < 1:
            continue
        unit = parts[0]
        if not (unit.startswith("zetronpoc-openvpn-") and unit.endswith(".service")):
            continue
        name = unit[len("zetronpoc-openvpn-"):-len(".service")]
        active = _svc_active(unit)
        rows.append({"name": name, "type": "openvpn",
                     "device": "tun" if active == "active" else "",
                     "state": "activa" if active == "active" else "inactiva"})
    return rows


# ===================== CLIENTE WIREGUARD (NATIVO wg-quick) =====================
_WG_DIR = "/etc/wireguard"


def _wg_conf_path(name):
    return os.path.join(_WG_DIR, name + ".conf")


def _wg_unit(name):
    return "wg-quick@%s.service" % name


def _has_wg_unit(name):
    rc, _, _ = _run(["systemctl", "cat", _wg_unit(name)], timeout=5)
    return rc == 0


def _wg_clients():
    rc, out, _ = _run(["systemctl", "list-unit-files", "wg-quick@*.service", "--no-legend"], timeout=8)
    rows = []
    for line in (out or "").splitlines():
        parts = line.split()
        if len(parts) < 1:
            continue
        unit = parts[0]
        if not (unit.startswith("wg-quick@") and unit.endswith(".service")):
            continue
        name = unit[len("wg-quick@"):-len(".service")]
        if name == "wg0":
            continue  # ese es el servidor
        active = _svc_active(unit)
        rows.append({"name": name, "type": "wireguard",
                     "device": "wg" if active == "active" else "",
                     "state": "activa" if active == "active" else "inactiva"})
    return rows


# ===================== CLIENTE (SALIENTE) =====================
def list_clients():
    rows = _ovpn_clients() + _wg_clients()
    rc, out, err = _run(["nmcli", "-t", "-f", "NAME,TYPE,DEVICE", "connection", "show"], timeout=10)
    if rc == 0:
        for line in out.splitlines():
            parts = line.split(":")
            if len(parts) < 3:
                continue
            name, typ, dev = parts[0], parts[1], parts[2]
            if typ == "vpn" or "vpn" in typ.lower() or typ == "wireguard":
                if any(r["name"] == name for r in rows):
                    continue
                rows.append({"name": name, "type": typ,
                             "device": dev if dev != "--" else "",
                             "state": "activa" if (dev and dev != "--") else "inactiva"})
    return rows


def _write_nm_keyfile(name, kind, d):
    """Escribe una conexion NM como keyfile con [vpn-secrets] embebidos,
    para que nmcli connection up no pida --ask (fix del error 'no valid secret')."""
    gateway = (d.get("gateway") or "").strip()
    user = (d.get("user") or "").strip()
    password = (d.get("password") or "").strip()
    psk = (d.get("psk") or "").strip()
    path = "/etc/NetworkManager/system-connections/%s.nmconnection" % name
    lines = [
        "[connection]",
        "id=%s" % name,
        "type=vpn",
        "autoconnect=false",
        "permissions=",
        "",
        "[vpn]",
        "gateway=%s" % gateway,
        "user=%s" % user,
        "password-flags=0",
    ]
    if kind == "l2tp":
        lines.append("service-type=org.freedesktop.NetworkManager.l2tp")
        if psk:
            lines.append("ipsec-enabled=true")
            lines.append("ipsec-psk-flags=0")
        else:
            lines.append("ipsec-enabled=false")
    else:
        lines.append("service-type=org.freedesktop.NetworkManager.pptp")
    lines += ["", "[vpn-secrets]"]
    if password:
        lines.append("password=%s" % password)
    if kind == "l2tp" and psk:
        lines.append("ipsec-psk=%s" % psk)
    lines += ["", "[ipv4]", "method=auto", "", "[ipv6]", "method=auto", ""]
    try:
        with open(path, "w") as f:
            f.write("\n".join(lines))
        os.chmod(path, 0o600)
    except PermissionError as e:
        return {"error": "sin permisos (¿backend como root?): %s" % e}
    _run(["nmcli", "connection", "reload"], timeout=10)
    return None


def create_client(d):
    name = (d.get("name") or "").strip()
    proto = (d.get("protocol") or "").strip().lower()
    gateway = (d.get("gateway") or "").strip()
    user = (d.get("user") or "").strip()
    password = (d.get("password") or "").strip()
    psk = (d.get("psk") or "").strip()
    ovpn = (d.get("ovpn_file") or "").strip()
    wg_config = (d.get("wg_config") or "").strip()
    wg_file = (d.get("wg_file") or "").strip()
    if not name or not VPN_NAME.match(name):
        return {"error": "nombre invalido (solo letras, numeros, _ -)"}
    if proto not in ("openvpn", "wireguard", "l2tp", "pptp"):
        return {"error": "protocolo invalido (openvpn/wireguard/l2tp/pptp)"}

    # ---------- WireGuard: nativo wg-quick ----------
    if proto == "wireguard":
        os.makedirs(_WG_DIR, exist_ok=True)
        conf_path = _wg_conf_path(name)
        try:
            if wg_config:
                with open(conf_path, "w") as f:
                    f.write(wg_config)
            elif wg_file and os.path.exists(wg_file):
                with open(wg_file, "r", errors="replace") as f:
                    content = f.read()
                with open(conf_path, "w") as f:
                    f.write(content)
            else:
                return {"error": "wireguard requiere el contenido .conf (pegado) o ruta de archivo"}
            os.chmod(conf_path, 0o600)
        except PermissionError as e:
            return {"error": "sin permisos: %s" % e}
        _run(["nmcli", "connection", "delete", name], timeout=10)
        _run(["systemctl", "enable", _wg_unit(name)], timeout=10)
        return {"ok": True, "salida": "Cliente WireGuard '%s' creado en %s. Usa Conectar." % (name, conf_path)}

    # ---------- OpenVPN: nativo (systemd) ----------
    if proto == "openvpn":
        if not gateway and not ovpn:
            return {"error": "openvpn requiere archivo .ovpn o gateway"}
        os.makedirs(_OVPN_DIR, exist_ok=True)
        conf_path = _ovpn_conf_path(name)
        auth_path = _ovpn_auth_path(name)
        _run(["nmcli", "connection", "delete", name], timeout=10)
        try:
            if ovpn and os.path.exists(ovpn):
                with open(ovpn, "r", errors="replace") as f:
                    content = f.read()
                with open(conf_path, "w") as f:
                    f.write(content)
            elif gateway:
                body = ("client\ndev tun\nproto udp\nremote %s\nresolv-retry infinite\n"
                        "nobind\npersist-key\npersist-tun\nremote-cert-tls server\n"
                        "verb 3\n") % gateway
                with open(conf_path, "w") as f:
                    f.write(body)
            else:
                return {"error": "openvpn requiere archivo .ovpn o gateway"}
        except PermissionError as e:
            return {"error": "sin permisos (¿backend como root?): %s" % e}
        if user and password:
            try:
                with open(auth_path, "w") as f:
                    f.write("%s\n%s\n" % (user, password))
                os.chmod(auth_path, 0o600)
            except PermissionError as e:
                return {"error": "sin permisos auth: %s" % e}
        else:
            if os.path.exists(auth_path):
                try:
                    os.remove(auth_path)
                except OSError:
                    pass
        try:
            _write_ovpn_unit(name)
        except PermissionError as e:
            return {"error": "sin permisos unit: %s" % e}
        return {"ok": True, "salida": "Cliente OpenVPN '%s' creado en %s (unit %s)." % (name, conf_path, _ovpn_unit(name))}

    # ---------- L2TP/PPTP: NetworkManager via keyfile (secretos embebidos) ----------
    if not gateway:
        return {"error": "falta gateway/servidor"}
    _run(["nmcli", "connection", "delete", name], timeout=10)
    err = _write_nm_keyfile(name, proto, d)
    if err:
        return err
    return {"ok": True, "salida": "Cliente %s '%s' creado (keyfile con secretos). Usa Conectar." % (proto.upper(), name)}


def _parse_vpn_data(raw):
    out = {}
    for kv in (raw or "").split(","):
        if "=" in kv:
            k, v = kv.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def get_client(name):
    if not name or not VPN_NAME.match(name):
        return {"error": "nombre invalido"}
    # WireGuard nativo
    if _has_wg_unit(name):
        gateway = ""; wg_config = ""
        try:
            with open(_wg_conf_path(name), "r", errors="replace") as f:
                wg_config = f.read()
            for line in wg_config.splitlines():
                s = line.strip()
                if s.startswith("Endpoint") and not gateway:
                    val = s.split("=", 1)[1].strip()
                    gateway = val.split(":")[0] if ":" in val else val
        except OSError:
            pass
        active = _svc_active(_wg_unit(name))
        return {"name": name, "type": "wireguard", "protocol": "wireguard",
                "gateway": gateway, "user": "", "password": "", "psk": "",
                "wg_config": wg_config, "wg_file": _wg_conf_path(name),
                "ovpn_file": "", "state": "activa" if active == "active" else "inactiva"}
    # OpenVPN nativo
    if _has_ovpn_unit(name):
        gateway = ""; user = ""; password = ""
        try:
            with open(_ovpn_conf_path(name), "r", errors="replace") as f:
                for line in f:
                    if line.strip().startswith("remote ") and not gateway:
                        gateway = line.split(None, 1)[1].strip()
            if os.path.exists(_ovpn_auth_path(name)):
                with open(_ovpn_auth_path(name), "r") as f:
                    ls = f.read().splitlines()
                if ls:
                    user = ls[0]
                    password = ls[1] if len(ls) > 1 else ""
        except OSError:
            pass
        active = _svc_active(_ovpn_unit(name))
        return {"name": name, "type": "openvpn", "protocol": "openvpn",
                "gateway": gateway, "user": user, "password": password,
                "psk": "", "ovpn_file": _ovpn_conf_path(name), "wg_config": "",
                "state": "activa" if active == "active" else "inactiva"}
    # L2TP/PPTP via NetworkManager
    rc, out, err = _run(["nmcli", "-t", "-f", "connection.type,vpn.data", "connection", "show", name], timeout=10)
    if rc != 0:
        return {"error": (err or "conexion no encontrada").strip()}
    ctype = ""; data = {}
    for line in (out or "").splitlines():
        if line.startswith("connection.type:"):
            ctype = line.split(":", 1)[1].strip()
        elif line.startswith("vpn.data:"):
            data = _parse_vpn_data(line.split(":", 1)[1])
    gateway = data.get("gateway") or data.get("remote") or ""
    user = data.get("user", "")
    proto = "pptp"
    if data.get("ipsec-enabled") or data.get("ipsec-psk"):
        proto = "l2tp"
    rc2, out2, _ = _run(["nmcli", "-s", "-t", "-f", "vpn.secrets", "connection", "show", name], timeout=10)
    password = ""; psk = ""
    for line in (out2 or "").splitlines():
        if line.startswith("vpn.secrets:"):
            sec = _parse_vpn_data(line.split(":", 1)[1])
            password = sec.get("password", "")
            psk = sec.get("ipsec-psk", "")
    return {"name": name, "type": ctype, "protocol": proto, "gateway": gateway,
            "user": user, "password": password, "psk": psk,
            "ovpn_file": "", "wg_config": ""}


def up(name):
    """Dispara la conexion (no bloquea mucho: el frontend sondea connect_log)."""
    if not name or not VPN_NAME.match(name):
        return {"error": "nombre invalido"}
    # WireGuard nativo
    if _has_wg_unit(name):
        rc, out, err = _run(["systemctl", "restart", _wg_unit(name)], timeout=20)
        return {"ok": rc == 0, "triggered": True, "salida": out, "error": (err if rc else None)}
    # OpenVPN nativo
    if _has_ovpn_unit(name):
        rc, out, err = _run(["systemctl", "restart", _ovpn_unit(name)], timeout=20)
        return {"ok": rc == 0, "triggered": True, "salida": out, "error": (err if rc else None)}
    # NM (L2TP/PPTP): lanzar en background y devolver; el popup sondea connect_log
    try:
        subprocess.Popen(["nmcli", "connection", "up", name],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
        return {"ok": True, "triggered": True, "salida": "conectando (NM)..."}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def down(name):
    if not name or not VPN_NAME.match(name):
        return {"error": "nombre invalido"}
    if _has_wg_unit(name):
        rc, out, err = _run(["systemctl", "stop", _wg_unit(name)], timeout=20)
        return {"ok": rc == 0, "salida": out, "error": (err if rc else None)}
    if _has_ovpn_unit(name):
        rc, out, err = _run(["systemctl", "stop", _ovpn_unit(name)], timeout=20)
        return {"ok": rc == 0, "salida": out, "error": (err if rc else None)}
    rc, out, err = _run(["nmcli", "connection", "down", name], timeout=30)
    return {"ok": rc == 0, "salida": out, "error": (err if rc else None)}


def delete_client(name):
    if not name or not VPN_NAME.match(name):
        return {"error": "nombre invalido"}
    ok = True; errs = []
    had_wg = _has_wg_unit(name)
    had_ovpn = _has_ovpn_unit(name)
    if had_wg:
        _run(["systemctl", "stop", _wg_unit(name)], timeout=20)
        _run(["systemctl", "disable", _wg_unit(name)], timeout=10)
        try:
            if os.path.exists(_wg_conf_path(name)):
                os.remove(_wg_conf_path(name))
        except OSError as e:
            errs.append(str(e))
    if had_ovpn:
        _run(["systemctl", "stop", _ovpn_unit(name)], timeout=20)
        _run(["systemctl", "disable", _ovpn_unit(name)], timeout=10)
        try:
            os.remove("/etc/systemd/system/%s" % _ovpn_unit(name))
        except OSError as e:
            errs.append(str(e))
        _run(["systemctl", "daemon-reload"], timeout=10)
        for p in (_ovpn_conf_path(name), _ovpn_auth_path(name)):
            try:
                if os.path.exists(p):
                    os.remove(p)
            except OSError as e:
                errs.append(str(e))
    # L2TP/PPTP (y legacy) via NM + keyfile fisico
    rc, out, err = _run(["nmcli", "connection", "delete", name], timeout=15)
    kp = "/etc/NetworkManager/system-connections/%s.nmconnection" % name
    try:
        if os.path.exists(kp):
            os.remove(kp)
        if os.path.exists(kp) or had_wg or had_ovpn:
            _run(["nmcli", "connection", "reload"], timeout=10)
    except OSError as e:
        errs.append(str(e))
    if rc != 0 and not had_ovpn and not had_wg:
        ok = False
        errs.append((err or "no encontrada").strip())
    return {"ok": ok, "salida": "eliminado", "error": "; ".join(errs) if errs else None}


# ===================== LOG DE CONEXION EN VIVO =====================
def connect_log(name, lines=80):
    """Tail del log del servicio de la conexion + estado. Lo sondea el popup
    del admin para mostrar 'me voy conectando a tal lado... Conexion establecida'."""
    if not name or not VPN_NAME.match(name):
        return {"error": "nombre invalido"}
    out_lines = []; kind = ""; state = "inactiva"; connected = False
    try:
        lines = int(lines)
    except (ValueError, TypeError):
        lines = 80
    if _has_wg_unit(name):
        kind = "wireguard"
        unit = _wg_unit(name)
        rc, out, _ = _run(["journalctl", "-u", unit, "-n", str(lines), "--no-pager"], timeout=8)
        out_lines = (out or "").splitlines()[-lines:]
        active = _svc_active(unit)
        state = "activa" if active == "active" else ("activando" if active == "activating" else "inactiva")
        rc2, wgout, _ = _run(["wg", "show"], timeout=5)
        connected = bool(wgout and re.search(r'\b%s\b' % re.escape(name), wgout) and "latest handshake" in wgout)
        if connected:
            state = "activa"
    elif _has_ovpn_unit(name):
        kind = "openvpn"
        unit = _ovpn_unit(name)
        rc, out, _ = _run(["journalctl", "-u", unit, "-n", str(lines), "--no-pager"], timeout=8)
        out_lines = (out or "").splitlines()[-lines:]
        active = _svc_active(unit)
        state = "activa" if active == "active" else ("activando" if active == "activating" else "inactiva")
        connected = state == "active" or any("Initialization Sequence Completed" in l for l in out_lines)
        if connected:
            state = "activa"
    else:
        kind = "nm"
        rc, out, _ = _run(["journalctl", "-u", "NetworkManager", "-n", str(lines * 2), "--no-pager"], timeout=8)
        out_lines = [l for l in (out or "").splitlines() if name in l][-lines:]
        rc3, sh, _ = _run(["nmcli", "-t", "-f", "NAME,DEVICE", "connection", "show", "--active"], timeout=6)
        active_names = [ln.split(":")[0] for ln in (sh or "").splitlines() if ln]
        connected = name in active_names
        state = "activa" if connected else "activando"
    return {"kind": kind, "name": name, "state": state, "connected": connected, "lines": out_lines}


# ===================== SERVIDOR (ENTRANTE) =====================
def server_status():
    swan = _swan_name()
    return {
        "openvpn": {"active": _svc_active("openvpn-server@server"), "enabled": _svc_enabled("openvpn-server@server")},
        "pptp": {"active": _svc_active("pptpd"), "enabled": _svc_enabled("pptpd")},
        "l2tp_ipsec": {"active": _svc_active(swan), "enabled": _svc_enabled(swan), "service": swan},
        "l2tp_xl2tpd": {"active": _svc_active("xl2tpd"), "enabled": _svc_enabled("xl2tpd")},
        "wireguard": {"active": _svc_active("wg-quick@wg0"), "enabled": _svc_enabled("wg-quick@wg0")},
        "listening": _listening_ports(),
    }


def _listening_ports():
    rc, out, _ = _run(["bash", "-c", "ss -tlnp 2>/dev/null | grep -E ':(1194|1723|500|4500|1701|51820)' || true"], timeout=6)
    return out.strip()


def server_apply(d):
    proto = (d.get("protocol") or "").strip().lower()
    if proto == "openvpn":
        return _openvpn_server(d)
    if proto == "pptp":
        return _pptp_server(d)
    if proto == "l2tp":
        return _l2tp_server(d)
    if proto == "wireguard":
        return _wireguard_server(d)
    return {"error": "protocolo invalido (openvpn/wireguard/pptp/l2tp)"}


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


def _wireguard_server(d):
    """Servidor WireGuard (wg-quick@wg0). Genera claves server+cliente y devuelve
    la config cliente lista para copiar."""
    try:
        port = int(d.get("port", 51820) or 51820)
    except (ValueError, TypeError):
        port = 51820
    addr = (d.get("address") or "10.9.0.1/24").strip()
    client_addr = (d.get("client_address") or "10.9.0.2/32").strip()
    os.makedirs(_WG_DIR, exist_ok=True)
    sk_path = os.path.join(_WG_DIR, "wg0.key")
    sp_path = os.path.join(_WG_DIR, "wg0.pub")
    ck_path = os.path.join(_WG_DIR, "wg0-client.key")
    cp_path = os.path.join(_WG_DIR, "wg0-client.pub")

    def _genpair(kp, pp):
        rc, k, e = _run(["wg", "genkey"], timeout=10)
        if rc != 0:
            return None, None, "wg genkey fallo (¿wireguard-tools instalado?): %s" % e
        k = k.strip()
        with open(kp, "w") as f:
            f.write(k)
        os.chmod(kp, 0o600)
        rc2, p, e2 = _run(["bash", "-c", "echo '%s' | wg pubkey" % k], timeout=10)
        if rc2 != 0:
            return None, None, "wg pubkey fallo: %s" % e2
        p = p.strip()
        with open(pp, "w") as f:
            f.write(p)
        return k, p, None

    if os.path.exists(sk_path):
        sk = open(sk_path).read().strip()
        sp = open(sp_path).read().strip()
    else:
        sk, sp, err = _genpair(sk_path, sp_path)
        if err:
            return {"error": err}
    if os.path.exists(ck_path):
        ck = open(ck_path).read().strip()
        cp = open(cp_path).read().strip()
    else:
        ck, cp, err = _genpair(ck_path, cp_path)
        if err:
            return {"error": err}

    conf = (
        "[Interface]\n"
        "Address = %s\n"
        "ListenPort = %d\n"
        "PrivateKey = %s\n"
        "PostUp = iptables -A FORWARD -i %%i -j ACCEPT; iptables -t nat -A POSTROUTING -j MASQUERADE\n"
        "PostDown = iptables -D FORWARD -i %%i -j ACCEPT; iptables -t nat -D POSTROUTING -j MASQUERADE\n"
        "\n"
        "[Peer]\n"
        "PublicKey = %s\n"
        "AllowedIPs = %s\n"
    ) % (addr, port, sk, cp, client_addr)
    path = os.path.join(_WG_DIR, "wg0.conf")
    try:
        with open(path, "w") as f:
            f.write(conf)
        os.chmod(path, 0o600)
    except PermissionError as e:
        return {"error": "sin permisos (¿backend como root?): %s" % e}
    # habilitar forwarding
    _run(["sysctl", "-w", "net.ipv4.ip_forward=1"], timeout=5)
    try:
        with open("/etc/sysctl.d/99-wireguard.conf", "w") as f:
            f.write("net.ipv4.ip_forward=1\n")
    except OSError:
        pass
    _run(["systemctl", "enable", "wg-quick@wg0"], timeout=10)
    rc, out, err = _run(["systemctl", "restart", "wg-quick@wg0"], timeout=20)
    # IP publica/local para el endpoint del cliente
    _, ipout, _ = _run(["bash", "-c", "hostname -I 2>/dev/null | awk '{print $1}'"], timeout=5)
    endpoint = (ipout.strip() or "<ip-del-servidor>")
    client_conf = (
        "[Interface]\nPrivateKey = %s\nAddress = %s\nDNS = 1.1.1.1\n\n"
        "[Peer]\nPublicKey = %s\nEndpoint = %s:%d\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n"
    ) % (ck, client_addr, sp, endpoint, port)
    return {"ok": rc == 0, "conf": path, "client_conf": client_conf,
            "server_pubkey": sp, "client_address": client_addr, "port": port,
            "error": (err if rc else None)}


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
    if proto == "wireguard":
        rc, out, err = _run(["systemctl", "stop", "wg-quick@wg0"], timeout=20)
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
        "wireguard-server": "wg-quick@wg0",
        "nm": "NetworkManager",
    }
    svc = svc_map.get(kind)
    if not svc:
        return {"error": "tipo invalido (openvpn/pptp/l2tp/xl2tpd/wireguard-server/nm)"}
    rc, out, err = _run(["journalctl", "-u", svc, "-n", str(lines), "--no-pager"], timeout=10)
    return {"lineas": (out or "").splitlines()[-lines:], "service": svc, "error": (err if rc else None)}