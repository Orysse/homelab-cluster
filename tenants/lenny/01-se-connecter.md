# Homelab abe.lc : ton accès

Tu as un espace à toi sur le cluster Kubernetes du homelab :

- le **namespace `lenny`**, dans lequel tu fais ce que tu veux ;
- les adresses **`lenny.abe.lc`** et **`*.lenny.abe.lc`** (par exemple `blog.lenny.abe.lc`),
  avec HTTPS déjà prêt.

Il te faut trois choses : un compte, la console web, et si tu veux travailler en ligne de
commande, `kubectl` à travers un VPN.

## 1. Ton compte (Pocket-ID)

Tu reçois un mail d'invitation de `homelab@abe.lc`. Le lien t'amène sur https://auth.abe.lc
où tu crées une **passkey** : il n'y a pas de mot de passe. Ta passkey peut être ton
téléphone, ton gestionnaire de mots de passe (Bitwarden, 1Password…), Windows Hello, Touch ID
ou une clé de sécurité.

Ajoute une deuxième passkey tout de suite (téléphone et ordinateur, par exemple), depuis
https://auth.abe.lc. Si tu les perds toutes, tu peux demander un code de connexion par mail
sur la page de login, ou demander à Abel.

Ce compte sert partout : console web, `kubectl`.

## 2. La console web (Headlamp)

https://k8s.abe.lc → *Sign in* → login Pocket-ID.

Choisis le namespace `lenny` (sélecteur en haut). Tu y vois tes pods, leurs logs, un
terminal dans les conteneurs, et tu peux créer ou modifier des objets en YAML. Ça suffit pour
tout faire, sans rien installer.

## 3. En ligne de commande

### 3.1 Installer les outils

| Outil | À quoi il sert |
|---|---|
| `kubectl` | parler au cluster |
| `kubelogin` (plugin `oidc-login`) | ton login Pocket-ID pour `kubectl` |
| WireGuard | le VPN : l'API Kubernetes n'est pas sur Internet |
| `flux` (optionnel) | si tu déploies depuis un repo git (voir l'autre guide) |

- **macOS** : `brew install kubectl int128/kubelogin/kubelogin fluxcd/tap/flux`, et
  l'app WireGuard depuis l'App Store.
- **Linux (Nix)** : `nix profile install nixpkgs#kubectl nixpkgs#kubelogin-oidc
  nixpkgs#fluxcd nixpkgs#wireguard-tools` (attention : le paquet `kubelogin` tout court est
  celui d'Azure, ce n'est pas le bon).
- **Autre Linux / Windows** : `kubectl` depuis https://kubernetes.io/docs/tasks/tools/, le
  plugin avec [krew](https://krew.sigs.k8s.io) (`kubectl krew install oidc-login`),
  WireGuard depuis https://www.wireguard.com/install/.

Vérifie : `kubectl oidc-login --help` doit répondre.

### 3.2 Le VPN

1. Dans l'app WireGuard : *Ajouter un tunnel vide* (elle génère tes clés). Sous Linux :
   `wg genkey | tee privatekey | wg pubkey > publickey`.
2. Envoie **ta clé publique** à Abel. Jamais la clé privée.
3. Quand il te dit que c'est fait, complète le tunnel :

```ini
[Interface]
PrivateKey = <ta clé privée, déjà remplie par l'app>
Address = 10.250.0.10/32

[Peer]
PublicKey = TNugHNt2qsBT5T/3ac1HWzXFzrw24rWu1l0uCKZhWEM=
Endpoint = vpn.abe.lc:51820
AllowedIPs = 192.168.1.211/32
PersistentKeepalive = 25
```

Le VPN ne donne accès qu'à l'API Kubernetes (`192.168.1.211:6443`), rien d'autre. Il ne
change pas le reste de ta connexion. Tu ne l'allumes que pour `kubectl`.

### 3.3 kubectl

Enregistre ce fichier sous `~/.kube/homelab.yaml` (il ne contient aucun secret) :

```yaml
apiVersion: v1
kind: Config
clusters:
  - name: homelab
    cluster:
      server: https://192.168.1.211:6443
      certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUJkekNDQVIyZ0F3SUJBZ0lCQURBS0JnZ3Foa2pPUFFRREFqQWpNU0V3SHdZRFZRUUREQmhyTTNNdGMyVnkKZG1WeUxXTmhRREUzT1RFME1EUTVNREl3SGhjTk1qWXhNREEzTVRreU9ESXlXaGNOTXpZeE1EQTBNVGt5T0RJeQpXakFqTVNFd0h3WURWUVFEREJock0zTXRjMlZ5ZG1WeUxXTmhRREUzT1RFME1EUTVNREl3V1RBVEJnY3Foa2pPClBRSUJCZ2dxaGtqT1BRTUJCd05DQUFUandEZkpVZnFDN08zTFRXeDZ6bHNVRHJHL2paT25IcDdDankzR1R3S2IKeUdoUEVxTDhvS2lCS0RkQjQ2QUpRSVhsUmZzV3g3akpidGdSR3hqb1pCNlVvMEl3UURBT0JnTlZIUThCQWY4RQpCQU1DQXFRd0R3WURWUjBUQVFIL0JBVXdBd0VCL3pBZEJnTlZIUTRFRmdRVXI4QW5pcXZ6azdMdE83VWVEVFJiClRNMWpYdzB3Q2dZSUtvWkl6ajBFQXdJRFNBQXdSUUlnRFdZdkQ3Y2tVRm9HRlJmV01IeGlnMnhpUG5sQnhGOEEKRXdIYW9FaHlER1lDSVFEYWNIM1g5TjZwMFQ2RVpHRWlzL2duOW9pM2JmaVV4TFk1V2QrNmNPVU5xQT09Ci0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0K
users:
  - name: lenny
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1
        command: kubectl
        args:
          - oidc-login
          - get-token
          - --oidc-issuer-url=https://auth.abe.lc
          - --oidc-client-id=46031658-1b1a-4d3b-8bfa-82dfaf67d4c4
          - --oidc-extra-scope=profile
          - --oidc-extra-scope=email
          - --oidc-extra-scope=groups
        interactiveMode: IfAvailable
contexts:
  - name: homelab
    context: { cluster: homelab, user: lenny, namespace: lenny }
current-context: homelab
```

Puis, VPN allumé :

```bash
export KUBECONFIG=~/.kube/homelab.yaml
kubectl get pods
```

La première commande ouvre ton navigateur sur Pocket-ID ; après le login, le jeton est gardé
en cache (`~/.kube/cache/oidc-login`) et les commandes suivantes passent directement.

`kubectl auth whoami` doit afficher `oidc:<ton nom>` et le groupe `oidc:tenant-lenny`.

## Ce que tu peux faire, ce que tu ne peux pas

| Oui | Non |
|---|---|
| Tout dans `lenny` : Deployments, Services, Secrets, volumes, Jobs, CronJobs, HTTPRoutes, rôles… | Toucher aux autres namespaces |
| Publier sur `lenny.abe.lc` et `*.lenny.abe.lc` | Prendre une autre adresse, ouvrir un port TCP/UDP brut |
| Sortir vers Internet depuis tes pods | Joindre le réseau de la maison ou les services du homelab |
| Déployer depuis ton propre repo git (Flux) | Lancer un conteneur root ou privilégié |

Ressources : 1 CPU et 1 Gio réservés, 2 CPU et 2 Gio au maximum, 20 pods, 10 Gio de disque.
Si tu as besoin de plus, demande.

Suite : **02-exposer-un-service.md**.

## En cas de souci

- `Unable to connect to the server` : le VPN n'est pas allumé, ou Abel n'a pas encore ajouté
  ta clé.
- `Forbidden` : tu n'es pas dans le namespace `lenny` (`-n lenny`), ou tu n'es pas encore dans
  le groupe `tenant-lenny` (Abel).
- Le navigateur ne s'ouvre pas : ouvre à la main l'URL `http://localhost:8000` affichée par
  la commande, sur la même machine.
- Login refusé après un changement de compte : `rm -rf ~/.kube/cache/oidc-login`.
