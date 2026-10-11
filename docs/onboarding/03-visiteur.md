# Visite guidée

Tu as un compte **visiteur** (groupe Pocket-ID `visitors`) : tu peux tout regarder, rien
modifier. Pas de secrets, pas de shell dans les pods, pas d'accès aux machines.

## 1. Ton compte

Le mail d'invitation de `homelab@abe.lc` t'amène sur https://auth.abe.lc, où tu crées une
**passkey** (téléphone, gestionnaire de mots de passe, Windows Hello, Touch ID…). Il n'y a
pas de mot de passe.

## 2. Sans rien installer

| Quoi | Où |
|---|---|
| Console Kubernetes (Headlamp) | https://k8s.abe.lc |
| Page de statut | https://status.abe.lc |

## 3. Avec le VPN

Installe Tailscale et connecte-le à notre serveur, `https://hs.abe.lc`
([comment faire](01-se-connecter.md#2-le-vpn-tailscale)). Commence par la page d'accueil :

| Quoi | Où |
|---|---|
| Page d'accueil : tous les services, la charge du cluster | https://home.int.abe.lc |
| Dashboards, logs, stats des sites (Grafana) | https://grafana.int.abe.lc |
| Flux réseau entre les pods (Hubble) | https://hubble.int.abe.lc |
| Routes HTTP (Traefik) | https://traefik.int.abe.lc/dashboard/ |

`kubectl` marche aussi, en lecture seule ([installation et kubeconfig](01-se-connecter.md#4-kubectl)).
`kubectl auth whoami` affiche le groupe `oidc:visitors`. Pour te balader :
`kubectl get pods -A`, `k9s`, `flux get all -A`.

Le code de tout ce que tu vois est public :
[homelab-nix](https://github.com/Orysse/homelab-nix) (les machines) et
[homelab-cluster](https://github.com/Orysse/homelab-cluster) (ce qui tourne dessus).

## Fin de visite

Déconnecte Tailscale, ou supprime le profil `hs.abe.lc` dans l'app. Abel retire ton
appareil et ton compte de son côté.
