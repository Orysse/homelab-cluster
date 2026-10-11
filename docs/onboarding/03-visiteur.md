# Homelab abe.lc : visite guidée

Tu as un compte **visiteur** (groupe Pocket-ID `visitors`) : tu peux tout regarder, rien
modifier. Pas de secrets, pas de shell dans les pods, pas d'accès aux machines.

Pour comprendre ce qui tourne et où : le [README du repo](../../README.md).

## 1. Ton compte

Tu reçois un mail d'invitation de `homelab@abe.lc`. Le lien t'amène sur https://auth.abe.lc
où tu crées une **passkey** (téléphone, gestionnaire de mots de passe, Windows Hello, Touch
ID…) : il n'y a pas de mot de passe.

## 2. Sans rien installer

| Quoi | Où |
|---|---|
| Console Kubernetes (Headlamp) | https://k8s.abe.lc |
| Page de statut (Gatus) | https://status.abe.lc |

## 3. Avec le VPN

Le reste n'est pas sur Internet. Installe Tailscale et connecte-le à notre serveur, comme
expliqué dans [Se connecter, 3.2](01-se-connecter.md#32-le-vpn-tailscale) (serveur
`https://hs.abe.lc`, login Pocket-ID).

| Quoi | Où |
|---|---|
| Dashboards, logs (Grafana) | https://grafana.int.abe.lc |
| Flux réseau entre les pods (Hubble) | https://hubble.int.abe.lc |
| Routes HTTP (Traefik) | https://traefik.int.abe.lc/dashboard/ |

`kubectl`, en lecture seule : [Se connecter, 3.1 et 3.3](01-se-connecter.md#31-installer-les-outils)
(outils et kubeconfig). `kubectl auth whoami` affiche le groupe `oidc:visitors`. Pour te
balader : `kubectl get pods -A`, `k9s`, `flux get all -A`.

## Fin de visite

Déconnecte Tailscale (ou supprime le profil `hs.abe.lc` dans l'app). Abel retire ton
appareil et ton compte de son côté.
