# Безопасная проверка VLESS на самом VPS

Эта проверка не меняет настройки и не перезапускает VPN. Она временно запустит второй клиент Xray только на `127.0.0.1`, сделает один запрос через серверный VLESS и остановит тестовый клиент. Для теста используется первый активный профиль, параметры берутся из существующих файлов. Они не выводятся. Тестовая конфигурация хранится в защищённом временном каталоге `/run` и удаляется при обычном завершении; тестовый процесс ограничен 30 секундами.

Проверка с VPS не проходит по сети Билайн и не проверяет профиль на телефоне. Если она сработала, это подтверждает работу тестового VLESS-профиля локально, но не объясняет клиентский тайм-аут. Если прямой запрос к Google не работает, результат через VPN может быть неинформативен.

Выполняйте от root, по одному блоку.

## 1. Каталог
```bash
install -d -m 700 /root/vless-check
```

## 2.1. Часть 1 из 3
```bash
cat > /root/vless-check/1 <<'EOF'
H4sIAAAAAAAC/6VX3W7kthW+n6dQHBSUshrNeL1pgzF0sa3d1ojjGLbXyGIwGMgSZ8wORxRI
an5gGEivEqAF+ggF8gSLIIu0TTd5BfmN+h1K82cbualsiBR5eH6/c3jm4486pdGdG5F3eD7z
iqW9VflBa29v74pPC6UTvfSkShPpXRy/Pj25etu5Pj2+vPR4nrWtamPwLDc28o4UN16urDdV
mRgtvevzswhcWoK4WC81s9D7i1F56CkTekaM80RiVOmEW4zlTaFVyg32LASPhOSYiSlvjbSa
ekVib6W48Rpu5/hstb66eP02Zk5/p6KzYqGTJWu9uTiN2a21hel1OvP5PBorNZY8StW0M+Y5
14nlw5fdV6zVyvjImeBDgcUyPlM5D3otD0+ixybus7TUkoWs/Ype5pLeCq9OxmedvJRur52q
POepbZPKqrRY+8ytT5OFW8PHvluZ4/WbO1JtmKqM37PBWpb3Ivb6OJMrpwoIHQvykfmUhW5x
4ImR52Yel4Y/ov+k4Wb1sjaBniLeeDfSZe6TrBd9uGgQpklhS82HULkobXylSx5avljNamPi
l/vBmhspHReRsRl2MGhR+JtdzcEu94qonhBx6I6Q2pLnPs2DOD7wEiCHPiJhMjEW1g9qg1i3
22WOH1+kvLDesRuEynsr7hSisKZrkV0uZq21zZnQiESYpbELa61coUVufVb98+Hrh39U/61+
rv7tVT9W76pfHr6ufn74q4f/6/PLnkfRjlnYMGF/vro6p880HMnS3Dq/1ByRLvHdvZuOlPak
J3KHS591tFK2MytyQsVIjCOQsgAuSbIhOdcPIlNIYaXIufGDTaTgIxYzYiSdfyidZCQbJ8PZ
ibZmLkjGx2zrHD2TcBbLmq8PJuF+cAix/ckqRIN4Fm0Y0cj22Gq6x/Zqo9KYcjSSKsmM31iz
yS9uU5dfncYuot01rOYicuSNcG4RZE0ajTm0EvmNKvPMsLA/CMhYUa8jhlalSjIA
EOF
```

## 2.2. Часть 2 из 3
```bash
cat > /root/vless-check/2 <<'EOF'
g80kYNrAuMEM2AUfxfs9nQgA5DqRJT/WWmmflbkpC6oIPGON6BjU/e7gEGBJ4ItlLPoMRvJk
esmtFfkYzPus2dwsucMzLGZDkZn4btGoDL7OjgXZ0ehrVqfCu/ugXkql4LmtLbvf4mWIGej9
RmDD4BYqnzSOqPWmqHqqgLUNfBqOEQonCzllEkTGrLSjNupIzueEnphBvcR4ow0WtJqbWAoA
HyejI5HaC4SHa3/USHIEfe2s0mQVLZCrda0cz5MbCX+iYK3xEQARc/AIiN7HRsgsEgHDksMK
Vv1QvSNNgNmGS1k614F87dTtbecBLFKN26Iid61DT+h3ukFRmgPO9eGjL794fXKGc483mitq
eP7m96cnfxh+fvwWWfIUNVNhDJzZIKY0XMckB6hxC2YS19dSVA9+cGgmEe6WzIfpL38XdfEH
F3SD4JCwF2MX4ok4T6bcD/r7AzqRSmV4U37S0Ti+Y1KNWc8Nks+4ZD2Wo3Kx+3CTGr0+9hE9
nmN3SxgjSaxH73CTMD3mLgdsrzEJ/klpbx1vN7m/H4QNOhhK9pacLTZ11u2ymeVIaUeYZJmm
/ec0orK6ymNaCF+9OgiCtUTybi0Nwe7RV7/GxiAE0lK9dKV95YmQjQA0fC2sNG1d6EV7JgwR
3A/wt+b6KKGhbM7tXOkJjtq0cIagkCPhsNCkHhYfZz3OjTDh2t0OIE1v0WxAjbUcrmdcnyGq
rEfVdAU9KF8kxkBi1mw8Az0QNYleG/4M8kFRCCTnV5DdQaRg46YarPqgaN2JHblLSeklehU+
EoumWrYRyBvedpcW+iFc8XVVyHpbt3Y+il09z4JOU63q8n1IW9EcvuJ1DXcXQFZOC+MDtcC4
QhG6RVfnE2XYVb/tdrfagVueTh43GH3qzOBuKIIGhm5hGlMWIm6OSzAI6wZi++TR8fXZm9NT
2uFaP7ez6kc+C7avTKfCVsPxTMbXBte3Ftscds3DlpxzV4D7bNPEHXSRFTvW/P9W
EOF
```

## 2.3. Часть 3 из 3
```bash
cat > /root/vless-check/3 <<'EOF'
uGt8iAo+NFgGuLeairqHSrJl/McE3dB6jYr10BXrBHj1P+0+uv3rpjCNCiUlVem6Fae+qHcD
fpMd4p3ucPU4yDV1L8URwKHpaaHhbuGjPA/WwYheosY6lcmMJ3yfim/6ui8vXXB6xCcykvPC
j/Z3AusuAOLcRPSizIl4J6bOmWy3PQ2pu66bv43aPfaC4uZ030bAui1ES/h99R7jf6p33sM3
bvq++tGrfsIO1qqfHv5efXj4GxpH9xNo3So6katGkUTvtIqPu1hKTN5r/Zrw6kP1vm5O3drD
t9DjQ/Uu8qrvqn9Vv/RYaJcF93kQDYd04wyHQQt1LJGyiWuDhm0YuMv3EUQcPFrbqECqT4SU
xdivSUUW1r/UosuTP10dX3yBG4825gm6zBUADjbufNKyP8Hdr0r4/OT0NHgOK+d1Cp0qNSmL
GjZUf1v/A7gg9f++DgAA
EOF
```

## 3. Соберите и проверьте файл
```bash
(set -o pipefail; cat /root/vless-check/1 /root/vless-check/2 /root/vless-check/3 | base64 -d | gzip -dc > /root/vless-check/probe.py)
```

```bash
echo 'bbeff9842e980b3fc48ef90d701c3a0d4c4a581d456c079e2d92ebd55de021fa  /root/vless-check/probe.py' | sha256sum -c - && python3 -m py_compile /root/vless-check/probe.py
```

Ожидается `OK`. При ошибке остановитесь.

## 4. Запустите тест
```bash
python3 /root/vless-check/probe.py
```

Дождитесь завершения: это может занять до минуты. Пришлите обе строки результата. Код `curl=0` с `HTTP=204` означает, что запрос прошёл. Другой HTTP-код при `curl=0` тоже означает полученный HTTP-ответ, но нужно учитывать возможную блокировку сайта. Ошибка с `HTTP=000` — ответ не получен. Не присылайте файлы клиента, ссылки и ключи.
