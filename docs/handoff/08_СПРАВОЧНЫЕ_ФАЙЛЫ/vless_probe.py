#!/usr/bin/env python3
"""Temporary local REALITY/VLESS end-to-end test. Does not modify VPN."""
import csv, json, os, signal, socket, subprocess, tempfile, time
from pathlib import Path

XRAY='/usr/local/bin/xray'
URL='https://www.google.com/generate_204'

def test(proxy=None):
    args=['curl','-4','-sS','-o','/dev/null','--connect-timeout','8','--max-time','18','-w','%{http_code}']
    args += ['--noproxy','','--socks5',proxy] if proxy else ['--noproxy','*']
    try:
        p=subprocess.run(args+[URL],capture_output=True,text=True,timeout=21)
        code=p.stdout.strip()
        return p.returncode, code if len(code)==3 and code.isdigit() else '000'
    except Exception: return None,'000'

proc=None
try:
    direct,dc=test()
    print('Прямой запрос с VPS: curl=',direct,'HTTP=',dc,flush=True)
    env={}
    for l in Path('/root/vpn-config.env').read_text().splitlines():
        if '=' in l and not l.lstrip().startswith('#'):
            k,v=l.split('=',1);env[k.strip()]=v.strip().strip('"').strip("'")
    c=json.loads(Path('/usr/local/etc/xray/config.json').read_text())
    ins=[i for i in c.get('inbounds',[]) if i.get('protocol')=='vless']
    if len(ins)!=1:raise ValueError('unsupported')
    i=ins[0]; reality=i['streamSettings']['realitySettings']
    valid_ids={x.get('id') for x in i.get('settings',{}).get('clients',[])}
    valid_sids=set(reality.get('shortIds',[]))
    with open('/root/clients.csv',encoding='utf-8',newline='') as f:
        rows=list(csv.DictReader(f))
    rows=[r for r in rows if r.get('enabled','1').strip().lower() in ('1','true','yes','да') and r.get('uuid') in valid_ids and r.get('short_id','') in valid_sids]
    if not rows or not env.get('DOMAIN') or not env.get('REALITY_PUBLIC_KEY'):raise ValueError('missing')
    user=rows[0]
    sk=socket.socket();sk.bind(('127.0.0.1',0));port=sk.getsockname()[1];sk.close()
    cfg={'log':{'loglevel':'none'},'inbounds':[{'listen':'127.0.0.1','port':port,'protocol':'socks','settings':{'auth':'noauth'}}],
      'outbounds':[{'protocol':'vless','settings':{'vnext':[{'address':'127.0.0.1','port':int(i.get('port',443)),
      'users':[{'id':user['uuid'],'encryption':'none','flow':'xtls-rprx-vision'}]}]},
      'streamSettings':{'network':'tcp','security':'reality','realitySettings':{'fingerprint':'chrome',
      'serverName':env['DOMAIN'],'password':env['REALITY_PUBLIC_KEY'],'shortId':user.get('short_id',''),'spiderX':'/'}}}]}
    with tempfile.TemporaryDirectory(prefix='vless-probe-',dir='/run') as d:
        conf=Path(d)/'client.json';conf.write_text(json.dumps(cfg));os.chmod(conf,0o600)
        check=subprocess.run([XRAY,'run','-test','-c',str(conf)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=8)
        if check.returncode:raise ValueError('clientconfig')
        proc=subprocess.Popen(['timeout','30s',XRAY,'run','-c',str(conf)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
        ready=False
        for _ in range(50):
            if proc.poll() is not None:break
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.2):ready=True
                break
            except OSError:time.sleep(.1)
        if not ready:raise RuntimeError('clientstart')
        code,http=test('127.0.0.1:'+str(port))
        print('Проверка через локальный VLESS: curl=',code,'HTTP=',http,flush=True)
except Exception as e:
    print('Проверка не завершена. Тип:',type(e).__name__)
finally:
    if proc is not None and proc.poll() is None:
        try:os.killpg(proc.pid,signal.SIGTERM);proc.wait(timeout=3)
        except Exception:
            try:os.killpg(proc.pid,signal.SIGKILL)
            except ProcessLookupError:pass
