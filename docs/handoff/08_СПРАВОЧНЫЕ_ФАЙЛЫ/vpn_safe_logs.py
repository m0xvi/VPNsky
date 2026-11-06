"""Generate fixed-vocabulary VPN diagnostic reports. Never forward raw logs."""
import datetime as dt, json, os, re, subprocess, tempfile, threading, time, urllib.request
from pathlib import Path

UNITS = [('Xray','xray.service'),('Hysteria2','hysteria-server.service'),('Nginx','nginx.service'),('SSH','ssh.service'),('VPN-бот','vpn-bot.service'),('Fail2ban','fail2ban.service')]
FILES = [('Xray access','/var/log/xray/access.log'),('Xray error','/var/log/xray/error.log'),('Nginx access','/var/log/nginx/access.log'),('Nginx error','/var/log/nginx/error.log'),('SSH auth','/var/log/auth.log'),('Fail2ban','/var/log/fail2ban.log')]
STATE=Path('/var/lib/vpn-safe-logs')
LOCK=threading.Lock()
MAX_LINES=200000
MAX_INPUT=128*1024*1024
MAX_LINE=1024*1024
MAX_REPORT=20*1024*1024


def menu():
    return {'inline_keyboard': [
        [{'text':'📊 Состояние служб','callback_data':'safe:status'}],
        [{'text':'🔵 Hysteria2 · 10 минут','callback_data':'safe:h2_10'},
         {'text':'🔵 Hysteria2 · 1 час','callback_data':'safe:h2_60'}],
        [{'text':'🟣 VLESS / Xray · 10 минут','callback_data':'safe:vl_10'},
         {'text':'🟣 VLESS / Xray · 1 час','callback_data':'safe:vl_60'}],
        [{'text':'📄 Общая сводка · 1 час','callback_data':'safe:1h'},
         {'text':'📄 Общая сводка · 24 часа','callback_data':'safe:24h'}]]}


def _dir():
    STATE.mkdir(mode=0o700,parents=True,exist_ok=True)
    os.chmod(STATE,0o700)


def register(cid,thread):
    # Only call this after bot allowlist and chat type checks.
    if not re.fullmatch(r'-[1-9][0-9]{0,19}',str(cid)): raise ValueError('bad chat')
    if thread is not None and (not isinstance(thread,int) or thread<=0): raise ValueError('bad thread')
    _dir(); tmp=STATE/'target.tmp'; target=STATE/'target.json'
    tmp.write_text(json.dumps({'chat_id':str(cid),'thread_id':thread}),encoding='utf-8');os.chmod(tmp,0o600);os.replace(tmp,target)


def message_text(v):
    # journalctl encodes messages with control characters as arrays of bytes.
    if isinstance(v,str): return v
    if isinstance(v,list):
        try: return bytes(v).decode('utf-8','replace')
        except (ValueError,TypeError): return ''
    return ''


def category(message, priority=6, source=''):
    # Never return substrings from the source. Every label is a constant.
    t=message_text(message).casefold()
    if source=='Hysteria2':
        if 'client disconnected' in t:
            if 'timeout' in t or 'timed out' in t: return 'Отключение клиента: тайм-аут / возможный простой'
            return 'Клиент отключился'
        if 'client connected' in t: return 'Клиент подключился'
        if 'tcp error' in t:
            if 'timeout' in t or 'timed out' in t: return 'Ошибка TCP: тайм-аут'
            if 'connection refused' in t: return 'Ошибка TCP: отказ в соединении'
            if 'connection reset' in t: return 'Ошибка TCP: соединение сброшено'
            return 'Ошибка TCP: другая причина'
        if 'udp error' in t: return 'Ошибка UDP'
    if 'already exists' in t and 'user' in t: return 'Возможное дублирование пользователя Xray'
    if any(x in t for x in ('failed password','authentication failure','invalid user','authentication failed')): return 'Ошибка авторизации'
    if any(x in t for x in ('timed out','timeout','deadline exceeded')): return 'Тайм-аут'
    if 'connection refused' in t: return 'Отказ в соединении'
    if 'connection reset' in t or 'connection abort' in t: return 'Соединение сброшено или прервано'
    if 'network is unreachable' in t: return 'Сеть недоступна'
    if any(x in t for x in ('tls handshake','reality verification failed','certificate verify failed')): return 'Ошибка TLS или REALITY'
    if 'unban ' in t or 'unbanned ' in t: return 'Снятие блокировки'
    if 'ban ' in t or 'banned ' in t: return 'Блокировка'
    if any(x in t for x in ('error','failed','critical','fatal')) or priority<=3: return 'Другая ошибка; подробности скрыты'
    if 'warning' in t or priority==4: return 'Другое предупреждение; подробности скрыты'
    return 'Прочее'


def timestamp_from_file(line):
    # Validated timestamps only; round to minute and publish in UTC.
    m=re.search(r'\b(20\d\d[-/]\d\d[-/]\d\d)[T ](\d\d:\d\d:\d\d)(?:[.,]\d+)?(Z|[+-]\d\d:?\d\d)?',line[:256])
    if m:
        stamp=m.group(1).replace('/','-')+'T'+m.group(2)+(m.group(3) or '')
        try:
            d=dt.datetime.fromisoformat(stamp.replace('Z','+00:00'))
            if d.tzinfo is None: d=d.astimezone()
            return d.astimezone(dt.timezone.utc)
        except ValueError: return None
    m=re.search(r'\[(\d\d/[A-Za-z]{3}/20\d\d:\d\d:\d\d:\d\d [+-]\d{4})\]',line[:256])
    if m:
        try: return dt.datetime.strptime(m.group(1),'%d/%b/%Y:%H:%M:%S %z').astimezone(dt.timezone.utc)
        except ValueError: pass
    return None


def ts(d): return d.astimezone(dt.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')


def send_doc(tok,cid,thread,path,proxy):
    boundary='vpn'+os.urandom(16).hex()
    def field(k,v): return ('--'+boundary+'\r\nContent-Disposition: form-data; name="'+k+'"\r\n\r\n'+str(v)+'\r\n').encode()
    data=field('chat_id',cid)+field('caption','Сводка VPN: категории и количества без исходных сообщений.')
    if thread: data+=field('message_thread_id',thread)
    data+=('--'+boundary+'\r\nContent-Disposition: form-data; name="document"; filename="vpn-events.txt"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n').encode()+Path(path).read_bytes()+b'\r\n'+('--'+boundary+'--\r\n').encode()
    req=urllib.request.Request('https://api.telegram.org/bot'+tok+'/sendDocument',data=data,headers={'Content-Type':'multipart/form-data; boundary='+boundary})
    op=urllib.request.build_opener(urllib.request.ProxyHandler({'http':proxy,'https':proxy}) if proxy else urllib.request.ProxyHandler())
    try:
        with op.open(req,timeout=60) as r: return bool(json.loads(r.read()).get('ok'))
    except Exception: return False


def report(hours,path):
    from collections import Counter
    now=dt.datetime.now(dt.timezone.utc); since=now-dt.timedelta(hours=hours)
    size=0; count=0; skipped=0; present=[]; missing=[]
    summary=Counter(); hourly=Counter()
    def add(when,source,msg,pri,kind):
        nonlocal count
        count+=1
        if count>MAX_LINES: raise ValueError('too many events')
        label=category(msg,pri,kind)
        summary[(source,label)]+=1
        if label!='Прочее': hourly[(when.strftime('%Y-%m-%d %H:00 UTC'),source,label)]+=1
    for label,unit in UNITS:
        p=subprocess.Popen(['journalctl','--no-pager','--output=json','--since',str(hours)+' hours ago','--unit',unit],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
        timer=threading.Timer(35,p.kill);timer.daemon=True;timer.start()
        try:
            while True:
                line=p.stdout.readline(MAX_LINE+1)
                if not line: break
                size+=len(line)
                if len(line)>MAX_LINE or size>MAX_INPUT: raise ValueError('source limit')
                try:
                    rec=json.loads(line); raw=str(rec.get('__REALTIME_TIMESTAMP',''))
                    if not raw.isascii() or not raw.isdigit(): skipped+=1;continue
                    moment=dt.datetime.fromtimestamp(int(raw)/1000000,dt.timezone.utc)
                    if moment < since or moment > now+dt.timedelta(minutes=1): continue
                    pri=rec.get('PRIORITY','6');pri=int(pri) if str(pri) in '01234567' and len(str(pri))==1 else 6
                except (json.JSONDecodeError,OverflowError,OSError,TypeError,ValueError,AttributeError):
                    skipped+=1;continue
                add(moment,label+' (journal)',rec.get('MESSAGE',''),pri,label)
            if p.wait()!=0: raise RuntimeError('journal error')
        finally:
            timer.cancel()
            if p.poll() is None: p.kill();p.wait()
            p.stdout.close()
    for label,filename in FILES:
        f=Path(filename)
        if not f.is_file() or f.is_symlink(): missing.append(label);continue
        present.append(label)
        with f.open('rb') as source:
            while True:
                raw=source.readline(MAX_LINE+1)
                if not raw:break
                size+=len(raw)
                if len(raw)>MAX_LINE or size>MAX_INPUT: raise ValueError('source limit')
                line=raw.decode('utf-8','replace'); when=timestamp_from_file(line)
                if when is None: skipped+=1;continue
                if since <= when <= now+dt.timedelta(minutes=1): add(when,label+' (файл)',line,6,label)
    with Path(path).open('w',encoding='utf-8',newline='\n') as out:
        out.write('СВОДКА СОБЫТИЙ VPN\nПериод: последние '+str(hours)+' ч; часовые интервалы UTC.\n')
        out.write('Только фиксированные категории и количества. Исходные строки, адреса и ключи не включены.\n')
        out.write('Категории определяются по признакам и могут ошибаться. Отключение по тайм-ауту может означать простой.\n\n')
        out.write('ИТОГО ПО ИСТОЧНИКАМ\n')
        for (source,label),n in sorted(summary.items()):
            out.write(source+' | '+label+' | '+str(n)+'\n')
        out.write('\nПО ЧАСАМ: ИНТЕРЕСНЫЕ СОБЫТИЯ\n')
        if not hourly: out.write('Не обнаружено среди доступных записей.\n')
        for (hour,source,label),n in sorted(hourly.items()):
            out.write(hour+' | '+source+' | '+label+' | '+str(n)+'\n')
        out.write('\nВсего разобранных записей: '+str(count)+'\nБез распознанного времени или некорректных: '+str(skipped)+'\n')
        out.write('Текущие файлы доступны: '+(', '.join(present) if present else 'нет')+'\n')
        out.write('Текущие файлы отсутствуют: '+(', '.join(missing) if missing else 'нет')+'\n')
        out.write('Журналы и файлы могут дублировать события. Ротированные файлы и нестандартные пути не включены.\n')
        out.write('Отсутствие событий не доказывает доступность VPN у клиентов.\n')
        if out.tell()>MAX_REPORT: raise ValueError('report too large')


def protocol_report(action, path):
    from collections import Counter
    h2=action.startswith('h2_'); minutes=10 if action.endswith('_10') else 60
    unit='hysteria-server.service' if h2 else 'xray.service'
    name='Hysteria2' if h2 else 'VLESS / Xray'
    now=dt.datetime.now(dt.timezone.utc); start=now-dt.timedelta(minutes=minutes)
    events=[]; counts=Counter(); sessions={}; skipped=0; read_bytes=0; read_records=0
    def add(when, kind, session=''):
        events.append((when,kind,session)); counts[kind]+=1
        if len(events)>MAX_LINES: raise ValueError('event limit')
    def session_id(message):
        # Ephemeral, per-report labels; original addresses never leave memory.
        pos=message.find('{')
        if pos<0: return ''
        try:
            payload,_=json.JSONDecoder().raw_decode(message[pos:]); addr=payload.get('addr')
            if not isinstance(addr,str) or not addr or len(addr)>256:return ''
            if addr not in sessions: sessions[addr]=len(sessions)+1
            return 'сессия '+str(sessions[addr])
        except (ValueError,TypeError,AttributeError):return ''
    def classify(message,priority,access=False):
        t=message.casefold()
        if access:
            return 'Запрос принят Xray' if 'accepted' in t else ''
        if h2:
            if 'client connected' in t:return 'Клиент подключился'
            if 'client disconnected' in t:
                if 'timeout' in t or 'timed out' in t:return 'Клиент отключился: тайм-аут / возможный простой'
                if 'h3 error (0x0)' in t:return 'Клиент отключился: закрытие HTTP/3 (0x0)'
                return 'Клиент отключился: причина не распознана'
            if 'tcp error' in t or 'udp error' in t:
                proto='TCP' if 'tcp error' in t else 'UDP'
                if 'timeout' in t or 'timed out' in t:return 'Ошибка '+proto+' потока: тайм-аут'
                if 'connection refused' in t:return 'Ошибка '+proto+' потока: отказ в соединении'
                if 'connection reset' in t:return 'Ошибка '+proto+' потока: соединение сброшено'
                return 'Ошибка '+proto+' потока: причина не распознана'
        if 'user' in t and 'already exists' in t:return 'Ошибка Xray: дубликат пользователя'
        if 'reality' in t and ('fail' in t or 'error' in t):return 'Ошибка REALITY'
        if 'auth' in t and ('fail' in t or 'invalid' in t):return 'Ошибка авторизации'
        if 'timeout' in t or 'timed out' in t:return 'Тайм-аут: подробности скрыты'
        if 'connection refused' in t:return 'Отказ в соединении'
        if 'connection reset' in t:return 'Соединение сброшено'
        if priority<=3 or any(x in t for x in ('error','failed','fatal')):return 'Другая ошибка: подробности скрыты'
        if priority==4:return 'Предупреждение: подробности скрыты'
        return ''
    p=subprocess.Popen(['journalctl','--unit',unit,'--since',str(minutes)+' minutes ago',
        '--output=json','--no-pager'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
    timer=threading.Timer(35,p.kill);timer.daemon=True;timer.start()
    try:
        while True:
            line=p.stdout.readline(MAX_LINE+1)
            if not line:break
            read_bytes+=len(line);read_records+=1
            if len(line)>MAX_LINE or read_bytes>MAX_INPUT or read_records>MAX_LINES:raise ValueError('source limit')
            try:
                rec=json.loads(line); v=rec.get('MESSAGE','')
                if isinstance(v,list):v=bytes(v).decode('utf-8','replace')
                if not isinstance(v,str):skipped+=1;continue
                stamp=str(rec.get('__REALTIME_TIMESTAMP',''))
                if not stamp.isascii() or not stamp.isdigit():skipped+=1;continue
                when=dt.datetime.fromtimestamp(int(stamp)/1000000,dt.timezone.utc)
                if when<start or when>now+dt.timedelta(minutes=1):continue
                pr=str(rec.get('PRIORITY','6'));priority=int(pr) if pr in ('0','1','2','3','4','5','6','7') else 6
                kind=classify(v,priority)
                if kind:add(when,kind,session_id(v) if h2 else '')
            except (ValueError,TypeError,OverflowError,OSError,AttributeError):
                skipped+=1
        if p.wait()!=0:raise RuntimeError('journal error')
    finally:
        timer.cancel()
        if p.poll() is None:p.kill();p.wait()
        p.stdout.close()
    sources=[]
    if not h2:
        for filename,access in [('/var/log/xray/access.log',True),('/var/log/xray/error.log',False)]:
            f=Path(filename)
            if not f.is_file() or f.is_symlink():continue
            sources.append('access' if access else 'error')
            with f.open('rb') as src:
                while True:
                    line=src.readline(MAX_LINE+1)
                    if not line:break
                    read_bytes+=len(line);read_records+=1
                    if len(line)>MAX_LINE or read_bytes>MAX_INPUT or read_records>MAX_LINES:raise ValueError('source limit')
                    raw=line.decode('utf-8','replace');when=timestamp_from_file(raw)
                    if when is None:skipped+=1;continue
                    if not start<=when<=now+dt.timedelta(minutes=1):continue
                    kind=classify(raw,6,access)
                    if kind:add(when,kind)
    with Path(path).open('w',encoding='utf-8',newline='\n') as out:
        out.write('СОБЫТИЯ '+name+'\nПериод: последние '+str(minutes)+' минут. Время UTC.\n')
        out.write('Только категории; IP, имена, сайты, ключи и исходные сообщения скрыты.\n')
        if h2:out.write('Сессии пронумерованы только внутри этого отчёта по исходному адресу и порту; номер не идентифицирует человека и может меняться.\n')
        else:out.write('Xray: принятые запросы видны только если ведётся access.log; запрос не равен числу пользователей.\n')
        out.write('\nСВОДКА\n')
        if not counts:out.write('Распознаваемых событий не найдено.\n')
        for label,n in sorted(counts.items()):out.write(label+': '+str(n)+'\n')
        out.write('\nХРОНОЛОГИЯ\n')
        for when,kind,session in sorted(events,key=lambda v:v[0]):
            out.write(when.strftime('%Y-%m-%d %H:%M:%S UTC')+' | '+kind+(' | '+session if session else '')+'\n')
        out.write('\nОбработано записей источников: '+str(read_records)+'; пропущено без формата/времени: '+str(skipped)+'\n')
        if not h2:out.write('Текущие файлы Xray доступны: '+(', '.join(sources) if sources else 'нет')+'. Ротации не включены.\n')
        out.write('Записи разных источников могут дублироваться. Пустой журнал не доказывает доступность VPN.\n')
        out.write('Тайм-аут может означать простой или потерю связи; сам по себе он не определяет причину.\n')
        if out.tell()>MAX_REPORT:raise ValueError('report limit')


def status():
    parts=[]
    for label,unit in UNITS:
        try:
            r=subprocess.run(['systemctl','is-active','--quiet',unit],timeout=5,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            parts.append(('🟢 ' if r.returncode==0 else '🔴 ')+label)
        except Exception: parts.append('⚪ '+label+' — проверка недоступна')
    v=os.statvfs('/');used=100-round(v.f_bavail*100/v.f_blocks) if v.f_blocks else 0
    return 'Состояние служб на VPS:\n'+'\n'.join(parts)+'\nДиск / занят: '+str(used)+'%\nЭто не проверка доступности VPN у клиентов.'


def _work(tok,cid,thread,proxy,action,notify):
    path=None
    try:
        if action=='status': notify(status());return
        fd,path=tempfile.mkstemp(prefix='vpn-safe-',suffix='.txt',dir='/root');os.close(fd)
        if action in {'h2_10','h2_60','vl_10','vl_60'}:
            protocol_report(action,path)
        else:
            report(1 if action=='1h' else 24,path)
        if not send_doc(tok,cid,thread,path,proxy): notify('Не удалось отправить файл отчёта. Проверьте доступ бота к этой группе и теме.')
    except ValueError:
        notify('Отчёт не сформирован: превышен лимит объёма или количества записей. Неполный файл не отправлен.')
    except Exception:
        notify('Отчёт не сформирован: ошибка чтения журнала или файлов. Подробности не выводятся.')
    finally:
        if path:
            try: os.unlink(path)
            except FileNotFoundError: pass
        LOCK.release()


def start(tok,cid,thread,proxy,action,notify):
    if action not in {'status','1h','24h','h2_10','h2_60','vl_10','vl_60'}: return
    if not LOCK.acquire(blocking=False): notify('Предыдущий отчёт ещё формируется.');return
    try: threading.Thread(target=_work,args=(tok,cid,thread,proxy,action,notify),daemon=True).start()
    except Exception: LOCK.release();raise
