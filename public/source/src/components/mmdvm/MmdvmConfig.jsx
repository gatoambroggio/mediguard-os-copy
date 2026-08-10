import React, { useState, useMemo } from "react";
import { Copy, Check } from "lucide-react";

const DEFAULTS = {
  callsign: "LU1ABC",
  serialPort: "/dev/ttyUSB0",
  baud: "115200",
  connectionType: "usb",
  uartSpeed: "115200",
  frequency: "433.800",
  duplex: "0",
  pocsagBaud: "1200",
  enablePocsag: true,
  enableVoice: false,
  txInvert: "1",
  txLevel: "50",
  txOffset: "0",
  pttDelay: "100",
  display: "None",
  dapnetEnable: false,
  dapnetAddress: "",
  dapnetPasscode: "",
};

export default function MmdvmConfig() {
  const [cfg, setCfg] = useState(DEFAULTS);
  const [copied, setCopied] = useState(false);

  const set = (k, v) => setCfg((c) => ({ ...c, [k]: v }));

  const ini = useMemo(() => {
    const modeFlags = cfg.enableVoice
      ? `DMR=1
DSTAR=1
YSF=1
P25=0
NXDN=0`
      : `DMR=0
DSTAR=0
YSF=0
P25=0
NXDN=0`;
    const connLines = cfg.connectionType === "uart"
      ? `Protocol=uart
UARTPort=${cfg.serialPort}
UARTSpeed=${cfg.uartSpeed}`
      : `BaudeRate=${cfg.baud}`;
    return `# MMDVM.ini — generado por ZetronPOC / MediGuard OS
# Modulo MMDVM UHF/VHF por puerto serie (sin Raspberry, sin .wav)

[General]
Callsign=${cfg.callsign}
Id=${cfg.callsign.replace(/\s/g, "")}000
Timeout=180
Duplex=${cfg.duplex}
RFModeHang=10
${modeFlags}
POCSAG=${cfg.enablePocsag ? "1" : "0"}
Display=${cfg.display}

[Modem]
Port=${cfg.serialPort}
${connLines}
TXInvert=${cfg.txInvert}
RXInvert=0
PTTInvert=0
TXDelay=${cfg.pttDelay}
RXLevel=50
DMRTXLevel=${cfg.txLevel}
DSTAR_TXLevel=${cfg.txLevel}
YSFTXLevel=${cfg.txLevel}
P25TXLevel=${cfg.txLevel}
NXDNTXLevel=${cfg.txLevel}
POCSAGTXLevel=${cfg.txLevel}
TXOffset=${cfg.txOffset}
RXOffset=${cfg.txOffset}
RSSIMapping=0:0,100:100
UseCOSAsLockout=0

[POCSAG]
Enable=${cfg.enablePocsag ? "1" : "0"}
Callsign=${cfg.callsign}

[DAPNET]
Enable=${cfg.dapnetEnable ? "1" : "0"}
Address=${cfg.dapnetAddress}
Passcode=${cfg.dapnetPasscode}

[Display]
Enabled=${cfg.display === "None" ? "0" : "1"}
Type=${cfg.display}
Port=${cfg.serialPort}

[Info]
Enabled=0

[Log]
DisplayLevel=1
FileLevel=1
FilePath=/var/log/mmdvm
FileRoot=MMDVM
`;
  }, [cfg]);

  const copiar = () => {
    navigator.clipboard.writeText(ini);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="grid lg:grid-cols-2 gap-5">
      {/* form */}
      <div className="rounded-[24px] bg-white/80 backdrop-blur-xl border border-slate-200 p-5">
        <h3 className="font-display font-bold text-slate-900 mb-4">Parametros del modulo</h3>
        <div className="grid sm:grid-cols-2 gap-3">
          <Field label="Callsign" value={cfg.callsign} onChange={(v) => set("callsign", v)} />
          <Select label="Conexion" value={cfg.connectionType} onChange={(v) => set("connectionType", v)} opts={[["usb", "USB / ttyUSB"], ["uart", "UART (ttyAMA0)"]]} />
          <Field label="Puerto serie" value={cfg.serialPort} onChange={(v) => set("serialPort", v)} mono />
          {cfg.connectionType === "uart" ? (
            <Field label="UART Speed" value={cfg.uartSpeed} onChange={(v) => set("uartSpeed", v)} mono />
          ) : (
            <Field label="Baudios" value={cfg.baud} onChange={(v) => set("baud", v)} mono />
          )}
          <Field label="Frecuencia (MHz)" value={cfg.frequency} onChange={(v) => set("frequency", v)} mono />
          <Field label="POCSAG baudios" value={cfg.pocsagBaud} onChange={(v) => set("pocsagBaud", v)} mono />
          <Field label="TX Level (0-100)" value={cfg.txLevel} onChange={(v) => set("txLevel", v)} mono />
          <Field label="TX Offset (Hz)" value={cfg.txOffset} onChange={(v) => set("txOffset", v)} mono />
          <Field label="TX Delay (ms)" value={cfg.pttDelay} onChange={(v) => set("pttDelay", v)} mono />
          <Select label="Modo" value={cfg.duplex} onChange={(v) => set("duplex", v)} opts={[["0", "Simplex"], ["1", "Duplex"]]} />
          <Select label="TX Invert" value={cfg.txInvert} onChange={(v) => set("txInvert", v)} opts={[["1", "Si"], ["0", "No"]]} />
          <Select label="Display" value={cfg.display} onChange={(v) => set("display", v)} opts={[["None", "Sin display"], ["OLED", "OLED SSD1306"], ["Nextion", "Nextion"]]} />
        </div>

        <div className="mt-4 space-y-2">
          <Toggle label="Habilitar POCSAG (paginacion)" checked={cfg.enablePocsag} onChange={(v) => set("enablePocsag", v)} />
          <Toggle label="Modos de voz (DMR/DStar/YSF)" checked={cfg.enableVoice} onChange={(v) => set("enableVoice", v)} />
          <Toggle label="DAPNET (red global de pagers)" checked={cfg.dapnetEnable} onChange={(v) => set("dapnetEnable", v)} />
        </div>

        {cfg.dapnetEnable && (
          <div className="mt-3 grid sm:grid-cols-2 gap-3 pt-3 border-t border-slate-200">
            <Field label="DAPNET Address (IP)" value={cfg.dapnetAddress} onChange={(v) => set("dapnetAddress", v)} mono />
            <Field label="DAPNET Passcode" value={cfg.dapnetPasscode} onChange={(v) => set("dapnetPasscode", v)} mono />
          </div>
        )}
      </div>

      {/* output */}
      <div className="rounded-[24px] bg-slate-900 text-slate-100 p-5 flex flex-col">
        <div className="flex items-center justify-between mb-3">
          <h3 className="font-display font-bold text-slate-100">MMDVM.ini generado</h3>
          <button
            onClick={copiar}
            className="inline-flex items-center gap-1.5 text-xs bg-white/10 hover:bg-white/20 border border-white/20 rounded-full px-3 py-1.5 transition"
          >
            {copied ? <Check className="w-3.5 h-3.5 text-emerald-400" /> : <Copy className="w-3.5 h-3.5" />}
            {copied ? "Copiado" : "Copiar"}
          </button>
        </div>
        <pre className="font-mono text-[11px] leading-relaxed text-emerald-300/90 whitespace-pre overflow-auto flex-1 max-h-[420px]">
{ini}
        </pre>
      </div>
    </div>
  );
}

function Field({ label, value, onChange, mono }) {
  return (
    <label className="block">
      <span className="block text-[11px] font-medium text-slate-500 mb-1">{label}</span>
      <input
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className={`w-full bg-white border border-slate-200 rounded-xl px-3 py-2 text-sm text-slate-800 outline-none focus:border-indigo-400 focus:ring-2 focus:ring-indigo-100 transition ${mono ? "font-mono" : ""}`}
      />
    </label>
  );
}

function Select({ label, value, onChange, opts }) {
  return (
    <label className="block">
      <span className="block text-[11px] font-medium text-slate-500 mb-1">{label}</span>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="w-full bg-white border border-slate-200 rounded-xl px-3 py-2 text-sm text-slate-800 outline-none focus:border-indigo-400 focus:ring-2 focus:ring-indigo-100 transition"
      >
        {opts.map(([v, l]) => (
          <option key={v} value={v}>{l}</option>
        ))}
      </select>
    </label>
  );
}

function Toggle({ label, checked, onChange }) {
  return (
    <button
      onClick={() => onChange(!checked)}
      className="flex items-center justify-between w-full bg-white border border-slate-200 rounded-xl px-3.5 py-2.5 text-left transition hover:border-indigo-300"
    >
      <span className="text-sm font-medium text-slate-700">{label}</span>
      <span className={`relative w-10 h-5 rounded-full transition ${checked ? "bg-emerald-500" : "bg-slate-300"}`}>
        <span className={`absolute top-0.5 w-4 h-4 rounded-full bg-white shadow transition ${checked ? "left-5" : "left-0.5"}`} />
      </span>
    </button>
  );
}