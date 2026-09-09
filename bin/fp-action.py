#!/usr/bin/env python3
"""fingerprint-ocv widget actions. Subcommands: status, enroll, verify, delete.

Talks the same D-Bus API the daemon exposes (net.reactivated.Fprint, the
fingerprint-ocv implementation of the old fprintd spec). NOTE the driver's
subtle signatures:

  Claim(user)          -> s        (registers who we are; NOT a scan)
  EnrollStart(name)    -> s        (name of the print to record, e.g. "primary")
  VerifyStart(name)    -> s        ("any" / "" = check against all enrolled)
  ListEnrolledFingers(user) -> as  (user name, returns print names)
  DeleteEnrolledFingers(user) -> nothing

The single string arg to Enroll/VerifyStart is the FINGER NAME, not the user.
Passing the user id there (the historical bug) makes verify treat "zimixin"
as a finger name -> is_any()=false, exists=false -> the daemon answers
Error.NoEnrolledPrints even when prints ARE enrolled.
"""
import dbus, dbus.mainloop.glib, sys, time, json
from gi.repository import GLib
from threading import Thread

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
BUS = "unix:path=/run/user/1000/bus"
USER = "zimixin"
DEV = "/net/reactivated/Device/0"
IFACE = "net.reactivated.Fprint.Device"
DEFAULT_ENROLL_NAME = "primary"   # the print name used when none is given
VERIFY_ALL = "any"                # driver's is_any() -> check every enrolled
# Preferred order when auto-picking an unused name (the widget calls enroll
# without a name; the driver keys prints by user+name and OVERWRITES on the
# same name — so a new enrollment MUST get a distinct name).
ENROLL_NAMES = ["primary", "secondary", "third", "fourth", "fifth",
                "right-thumb", "left-thumb", "right-index", "left-index"]

def bus_obj():
    b = dbus.bus.BusConnection(BUS)
    return b.get_object("net.reactivated.Fprint", DEV)

def iface(obj):
    return dbus.Interface(obj, IFACE)

def _claim(d):
    try:
        iface(d).Claim(USER)
        return True
    except dbus.DBusException as e:
        print("CLAIM_FAILED %s" % e.get_dbus_name(), flush=True)
        return False
    except Exception:
        return False

def _stop(d):
    for m in ("EnrollStop", "VerifyStop"):
        try: getattr(iface(d), m)()
        except Exception: pass

def _guard(what, fn):
    """Run a scan-call, translating driver errors into one clean message so the
    floating terminal never dumps a python traceback at the user."""
    try:
        fn()
    except dbus.DBusException as e:
        ename = e.get_dbus_name() or ""
        msg = e.get_dbus_message() or ""
        if "NoEnrolledPrints" in ename:
            print("ОШИБКА: отпечаток не записан. Сначала нажми «Зарегистрировать».",
                  flush=True)
        elif "NoActionInProgress" in ename:
            print("ОШИБКА: прошлая операция ещё не завершена (повтори через секунду).",
                  flush=True)
        elif "AlreadyInUse" in ename:
            print("ОШИБКА: датчик уже занят другой операцией.", flush=True)
        elif "Timeout" in ename or "timed out" in (msg or "").lower():
            print("ОШИБКА: драйвер не отвечает. Перезапусти услугу fingerprint-ocv.",
                  flush=True)
        elif "ServiceUnknown" in ename or "NameHasNoOwner" in ename:
            print("ОШИБКА: драйвер не запущен (нет шины net.reactivated.Fprint).",
                  flush=True)
        else:
            print("ОШИБКА: %s %s" % (ename, msg), flush=True)
        return False
    except dbus.exceptions.DBusException as e:
        print("ОШИБКА: %s" % (e,), flush=True)
        return False
    except Exception as e:
        print("ОШИБКА: %s" % (e,), flush=True)
        return False
    return True

def cmd_status(obj):
    i = iface(obj)
    names = []
    try:
        raw = list(i.ListEnrolledFingers(USER))
        names = [str(x) for x in raw if str(x)]
    except dbus.DBusException as e:
        if "NoEnrolledPrints" in (e.get_dbus_name() or ""):
            names = []
        else:
            names = []
    except Exception:
        names = []
    try:
        fp = bool(i.Get("net.reactivated.Fprint.Device", "finger-present",
                        dbus_interface="org.freedesktop.DBus.Properties"))
    except Exception:
        fp = False
    print(json.dumps({
        "ready": True,
        "enrolled": len(names) > 0,
        "count": len(names),
        "names": names,
        "finger_present": fp,
        "generated_at": int(time.time()),
    }, ensure_ascii=False))
    return 0

def _run_scan(obj, kind, name):
    i = iface(obj)
    if not _claim(obj):
        print("CLAIM_FAILED — не могу взять датчик.", flush=True)
        return 1
    if kind == "verify":
        try:
            enrolled = list(i.ListEnrolledFingers(USER))
        except Exception:
            enrolled = []
        if not enrolled:
            print("Отпечаток не записан — сначала нажми «Зарегистрировать».", flush=True)
            return 1
    TOT = 10  # num-enroll-stages
    loop = GLib.MainLoop()
    status = {"done": False, "result": "timeout", "stage": 0, "presses": 0}

    bar_w = 20
    def render():
        s = status["stage"]
        f = int(round(bar_w * s / TOT))
        bar = "█" * f + "░" * (bar_w - f)
        if kind == "enroll":
            return "\rЭтап %d/%d  [%s]   нажатий: %d" % (s, TOT, bar, status["presses"])
        return "\rПроверка…  нажатий: %d" % status["presses"]

    def paint():
        print(render(), end="", flush=True)

    def emit(sig, ok):
        s = str(sig)
        if kind == "enroll":
            if s.startswith("enroll-completed"):
                status["result"] = "completed"; status["done"] = True
                print("\nГотово: отпечаток «%s» записан." % name, flush=True)
                loop.quit()
            elif s.startswith("enroll-stage-passed"):
                status["stage"] = status["stage"] + 1
                paint()
            elif s.startswith("enroll-remove-and-retry"):
                status["presses"] = status["presses"] + 1
                paint()
        else:
            status["presses"] = status["presses"] + 1
            if s.startswith("verify-match"):
                status["result"] = "match"; status["done"] = True
                print("\nСовпадение найдено.", flush=True); loop.quit()
            elif s.startswith("verify-"):
                if s.startswith("verify-retry"):
                    paint()
    try:
        i.connect_to_signal("EnrollStatus" if kind == "enroll" else "VerifyStatus", emit)
    except Exception as e:
        print("ОШИБКА подписки: %s" % e, flush=True)
    Thread(target=loop.run, daemon=True).start()

    print(("Запись «%s». Коснись датчика: палец ~1с держать, отпустить, пауза ~2с, повторять." % name)
          if kind == "enroll" else
          "Проверка. Коснись датчика любым записанным пальцем.", flush=True)
    ok = _guard(kind, lambda: (i.EnrollStart(name) if kind == "enroll" else i.VerifyStart(name)))
    if not ok:
        print("", flush=True)
        return 1
    t0 = time.time()
    while time.time() - t0 < 120 and not status["done"]:
        time.sleep(0.25)
    if not status["done"]:
        print("\nТаймаут 120с — прервано.", flush=True)
        status["result"] = "timeout"
    _stop(obj)
    print("\nEND", flush=True)
    return 0

def _pick_enroll_name(obj):
    """Return an enrolled-name that does not already exist (so a new print is
    added, never evicted). Falls back to finger-<N> once the list is used up."""
    try:
        i = iface(obj)
        existing = set(str(x) for x in i.ListEnrolledFingers(USER))
    except Exception:
        existing = set()
    for cand in ENROLL_NAMES:
        if cand not in existing:
            return cand
    n = len(existing) + 1
    while ("finger-%d" % n) in existing:
        n += 1
    return "finger-%d" % n

def cmd_delete(obj):
    i = iface(obj)
    _claim(obj)
    try:
        i.DeleteEnrolledFingers(USER)
        print("DELETED ok", flush=True)
    except Exception as e:
        print("DELERR %s" % e, flush=True)
    try:
        i.DeleteEnrolledFingers2()
    except Exception:
        pass
    return 0

def main():
    obj = bus_obj()
    args = sys.argv[1:]
    cmd = args[0] if len(args) > 0 else "status"
    if cmd == "status":
        return cmd_status(obj)
    if cmd == "enroll" or cmd == "verify":
        name = args[1] if len(args) > 1 else (DEFAULT_ENROLL_NAME if cmd == "enroll" else VERIFY_ALL)
        if cmd == "enroll" and len(args) < 2:
            name = _pick_enroll_name(obj)
        return _run_scan(obj, cmd, name)
    if cmd == "delete":
        return cmd_delete(obj)
    if cmd in ("-h", "--help"):
        print("usage: fp-action.py status|enroll[ NAME]|verify[ NAME]|delete")
        print("  enroll  NAME   записать отпечаток под именем NAME (по умолч. primary)")
        print("  verify  NAME   проверить NAME (по умолч. any — любой отпечаток)")
        return 0
    print("unknown command: %s" % cmd)
    return 2

if __name__ == "__main__":
    try:
        sys.exit(main())
    except dbus.exceptions.DBusException as e:
        print("ОШИБКА подключения к драйверу: %s" % e, flush=True)
        sys.exit(1)