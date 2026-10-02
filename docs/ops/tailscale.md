# Tailscale-Einrichtung für den ASR-Server

Ziel: Der ASR-Adapter ist nur aus dem eigenen Tailnet erreichbar, verschlüsselt über HTTPS, und nur von den eigenen Geräten. Hostnamen, IP-Adressen und Tokens gehören nicht in dieses Repository; Platzhalter sind mit `<...>` markiert.

## Überblick

```text
iPhone (Tailscale-Client)  ──HTTPS──▶  <asr-host>.<tailnet>.ts.net:443  (tailscale serve)
                                              │
                                              ▼  127.0.0.1:8765  Adapter (FastAPI)
                                              │
                                              ▼  127.0.0.1:8080  whisper-server
```

Weder Adapter noch `whisper-server` binden an eine öffentliche Adresse. Nur `tailscale serve` nimmt Verbindungen an, und nur aus dem Tailnet.

## 1. Server taggen

Dem Server-Knoten in der Admin-Konsole (Machines → Knoten → Edit ACL tags) das Tag `tag:asr` geben. Alternativ beim Anmelden:

```sh
sudo tailscale up --advertise-tags=tag:asr
```

Dafür muss das Tag in der Policy unter `tagOwners` deklariert sein (siehe unten).

## 2. Access-Control-Policy

In der Admin-Konsole unter Access Controls. Der Ausschnitt ergänzt eine bestehende Policy; die Standardregel `allow all` sollte entfernt oder eingeschränkt werden.

```jsonc
{
  "tagOwners": {
    "tag:asr": ["autogroup:admin"]
  },
  "acls": [
    // Eigene Geräte dürfen den ASR-Dienst auf Port 443 erreichen.
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:asr:443"] },
    // Admin-Zugang per SSH auf den Server, falls gewünscht.
    { "action": "accept", "src": ["autogroup:admin"], "dst": ["tag:asr:22"] }
  ],
  "nodeAttrs": [
    // Erlaubt dem Server, Zertifikate für HTTPS auszustellen.
    { "target": ["tag:asr"], "attr": ["funnel"] }
  ]
}
```

Hinweis zu `nodeAttrs`: Das Attribut `funnel` ist für `tailscale cert` nicht nötig; für HTTPS reicht die Option „HTTPS Certificates“ unter DNS. Den `nodeAttrs`-Block nur einfügen, wenn Tailscale ihn verlangt, und Funnel selbst nie aktivieren.

Prüfen in der Admin-Konsole unter Access Controls → Preview: Ein eigenes Gerät erreicht `tag:asr:443`, ein fremder Nutzer nicht.

## 3. HTTPS per `tailscale serve`

Einmalig in der Admin-Konsole unter DNS die Option „HTTPS Certificates“ einschalten. Dann auf dem Server:

```sh
# Adapter läuft lokal auf 127.0.0.1:8765
sudo tailscale serve --bg --https=443 http://127.0.0.1:8765
sudo tailscale serve status
```

Die Ausgabe zeigt die private URL `https://<asr-host>.<tailnet>.ts.net`. Diese URL wird in der iOS-App als Server-Adresse eingetragen.

Zertifikatsnamen landen in öffentlichen Certificate-Transparency-Logs. Deshalb einen neutralen Hostnamen für den Server wählen (z. B. `asr`), der nichts über Person oder Inhalt verrät.

**Funnel nie aktivieren.** `tailscale funnel` würde den Dienst öffentlich erreichbar machen. Prüfen mit:

```sh
sudo tailscale funnel status   # erwartet: "No serve config" oder keine Funnel-Einträge
```

## 4. Verbindungstest

Vom iPhone oder Mac im Tailnet:

```sh
curl -s https://<asr-host>.<tailnet>.ts.net/v1/health
```

Erwartet: JSON mit `"status": "ok"`. Vom selben Gerät ohne Tailscale oder von einem fremden Netz: Verbindung schlägt fehl (DNS-Fehler oder Timeout).

## 5. Token

Der Adapter liest den Token aus der Umgebungsvariable `MITSCHRIFT_TOKEN`. Erzeugen mit:

```sh
openssl rand -hex 32
```

Ablage auf dem Server in einer Datei mit Rechten `600`, die vom Startskript gelesen wird (z. B. `/etc/mitschrift/env`). In der iOS-App wird der Token einmal eingegeben und im Schlüsselbund gespeichert. Der Token steht nirgends im Repository, in Logs oder in Screenshots.

## Checkliste vor dem ersten Gerätetest

- [ ] Server trägt `tag:asr`
- [ ] Policy erlaubt nur `autogroup:member` → `tag:asr:443`
- [ ] „HTTPS Certificates“ aktiviert, `tailscale serve status` zeigt die HTTPS-URL
- [ ] `tailscale funnel status` zeigt keinen Funnel
- [ ] Adapter und `whisper-server` binden nur an `127.0.0.1`
- [ ] `/v1/health` aus dem Tailnet erreichbar, von außen nicht
- [ ] Token gesetzt, Anfrage ohne Token liefert 401
