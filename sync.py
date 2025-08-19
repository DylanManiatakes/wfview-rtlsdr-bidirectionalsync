#!/usr/bin/env python3
import socket
import time
import logging
import signal
import os

def _load_env_file():
    """Load key=value pairs from an env file into os.environ if not already set.
    Search order: $SDRSYNC_ENV_FILE, ./../.env, ./.env, /etc/sdrsync/sdrsync.env
    """
    candidates = []
    if os.getenv("SDRSYNC_ENV_FILE"):
        candidates.append(os.getenv("SDRSYNC_ENV_FILE"))
    # repo-local .env (common while developing)
    candidates.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".env")))
    candidates.append(os.path.abspath(os.path.join(os.path.dirname(__file__), ".env")))
    # system install location
    candidates.append("/etc/sdrsync/sdrsync.env")
    for path in candidates:
        try:
            if path and os.path.isfile(path):
                with open(path, "r", encoding="utf-8") as f:
                    for raw in f:
                        line = raw.strip()
                        if not line or line.startswith("#"):
                            continue
                        if "=" not in line:
                            continue
                        k, v = line.split("=", 1)
                        k = k.strip()
                        v = v.strip().strip('"').strip("'")
                        # don't override variables already in env
                        if k and k not in os.environ:
                            os.environ[k] = v
                break
        except Exception:
            # fail-soft if env file can't be read
            continue

_load_env_file()


# ---- CONFIG (env-driven, with defaults) ----
WF_HOST = os.getenv("WF_HOST", "127.0.0.1")
WF_PORT = int(float(os.getenv("WF_PORT", "4533")))
RTL_HOST = os.getenv("SDR_HOST", "192.168.155.245")
RTL_PORT = int(float(os.getenv("SDR_PORT", "4532")))
POLL_MS = int(float(os.getenv("POLL_MS", "200")))
TIMEOUT = float(os.getenv("TIMEOUT", "3.0"))
RECONNECT_WAIT = float(os.getenv("RECONNECT_WAIT", "2.0"))
CHANGE_THRESHOLD_HZ = int(float(os.getenv("CHANGE_THRESHOLD_HZ", "50")))
LOG_LEVEL = os.getenv("LOG_LEVEL", "DEBUG").upper()
# -------------------------------------------

stop = False

def setup_logging():
    logging.basicConfig(
        level=getattr(logging, LOG_LEVEL),
        format="%(asctime)s.%(msecs)03d [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
    )

# ---- socket helpers ----

def connect(host: str, port: int, name: str) -> socket.socket:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(TIMEOUT)
    logging.info(f"Connecting to {name} at {host}:{port} ...")
    s.connect((host, port))
    logging.info(f"Connected to {name}.")
    return s

def send_line(sock: socket.socket, line: str, peer: str):
    if not line.endswith("\n"):
        line = line + "\n"
    logging.debug(f"TX -> {peer}: {line.rstrip()}")
    sock.sendall(line.encode("ascii", errors="ignore"))


def recv_text(sock: socket.socket, peer: str, max_bytes: int = 1024) -> str:
    data = sock.recv(max_bytes)
    text = data.decode(errors="ignore")
    logging.debug(f"RX <- {peer}: {text.rstrip()}")
    return text

# ---- RigCTL helpers ----

def parse_freq_from_text(text: str) -> int | None:
    clean = text.strip()
    for token in clean.replace(":", " ").split():
        tok = "".join(ch for ch in token if (ch.isdigit() or ch in ".-"))
        if not tok:
            continue
        try:
            return int(tok)
        except ValueError:
            try:
                fval = float(tok)
                ival = int(round(fval))
                return ival
            except ValueError:
                continue
    return None


def rigctl_get_freq(sock: socket.socket, name: str) -> int | None:
    send_line(sock, "f", name)
    reply = recv_text(sock, name)
    freq = parse_freq_from_text(reply)
    if freq is None:
        logging.warning(f"{name}: could not parse frequency from '{reply.strip()}'")
    return freq


def rigctl_set_freq(sock: socket.socket, name: str, freq: int) -> bool:
    send_line(sock, f"F {freq}", name)
    reply = recv_text(sock, name)
    ok = ("RPRT 0" in reply) or reply.strip().isdigit()
    if not ok:
        logging.warning(f"{name}: set freq not acknowledged: '{reply.strip()}'")
    return ok

# ---- change tracking ----

class Tracker:
    def __init__(self, threshold_hz: int):
        self.th = threshold_hz
        self.last = {"wf": None, "sdr": None}
        self.last_change_time = {"wf": 0.0, "sdr": 0.0}

    def update(self, side: str, new_val: int):
        old = self.last[side]
        if old is None or abs(new_val - old) >= self.th:
            self.last_change_time[side] = time.time()
            logging.debug(f"{side} changed: {old} -> {new_val} (Δ={None if old is None else abs(new_val-old)} Hz)")
        self.last[side] = new_val

    def last_changed_side(self) -> str | None:
        wf_t = self.last_change_time["wf"]
        sdr_t = self.last_change_time["sdr"]
        if wf_t == 0.0 and sdr_t == 0.0:
            return None
        return "wf" if wf_t >= sdr_t else "sdr"

# ---- main loop ----

def sigint_handler(signum, frame):
    global stop
    stop = True
    logging.info("Ctrl-C received, exiting...")


def main():
    setup_logging()
    signal.signal(signal.SIGINT, sigint_handler)
    logging.info(f"wfview @ {WF_HOST}:{WF_PORT} | rigctl @ {RTL_HOST}:{RTL_PORT}; poll={POLL_MS}ms, thres={CHANGE_THRESHOLD_HZ}Hz")

    poll_sec = max(0.02, POLL_MS / 1000.0)
    tr = Tracker(CHANGE_THRESHOLD_HZ)

    wf = None
    sdr = None

    while not stop:
        # ensure connections
        try:
            if wf is None:
                wf = connect(WF_HOST, WF_PORT, "wfview")
            if sdr is None:
                sdr = connect(RTL_HOST, RTL_PORT, "rigctl")
        except Exception as e:
            logging.error(f"Connect error: {e}. Retrying in {RECONNECT_WAIT:.1f}s ...")
            for so in (wf, sdr):
                try:
                    if so: so.close()
                except Exception:
                    pass
            wf = sdr = None
            time.sleep(RECONNECT_WAIT)
            continue

        try:
            wf_freq = rigctl_get_freq(wf, "wfview")
            sdr_freq = rigctl_get_freq(sdr, "rigctl")

            if wf_freq is not None:
                tr.update("wf", wf_freq)
            if sdr_freq is not None:
                tr.update("sdr", sdr_freq)

            if wf_freq is not None and sdr_freq is not None:
                delta = abs(wf_freq - sdr_freq)
                if delta >= CHANGE_THRESHOLD_HZ:
                    source = tr.last_changed_side()
                    if source == "wf":
                        logging.info(f"Sync rigctl -> {wf_freq} Hz (Δ={delta})")
                        rigctl_set_freq(sdr, "rigctl", wf_freq)
                    elif source == "sdr":
                        logging.info(f"Sync wfview -> {sdr_freq} Hz (Δ={delta})")
                        rigctl_set_freq(wf, "wfview", sdr_freq)
                    else:
                        # tie-breaker: prefer wfview as source
                        logging.info(f"(tie) Sync rigctl -> {wf_freq} Hz (Δ={delta})")
                        rigctl_set_freq(sdr, "rigctl", wf_freq)
                else:
                    logging.debug(f"In sync (Δ={delta} Hz < {CHANGE_THRESHOLD_HZ}).")

            time.sleep(poll_sec)

        except (socket.timeout, ConnectionResetError, BrokenPipeError) as e:
            logging.error(f"I/O error: {e}. Reconnecting in {RECONNECT_WAIT:.1f}s ...")
            for so in (wf, sdr):
                try:
                    if so: so.close()
                except Exception:
                    pass
            wf = sdr = None
            time.sleep(RECONNECT_WAIT)
        except Exception as e:
            logging.exception(f"Unexpected error: {e}")
            time.sleep(poll_sec)

    for so in (wf, sdr):
        try:
            if so: so.close()
        except Exception:
            pass
    logging.info("Exited cleanly.")

if __name__ == "__main__":
    main()
