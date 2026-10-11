# Homelab abe.lc : ton accès admin

Tu es **admin du cluster Kubernetes** du homelab (groupe Pocket-ID `admins`) : tous les
namespaces, Grafana, OpenBao (les secrets). La machine elle-même (nuc1, NixOS) reste gérée
par Abel, dans le repo `homelab-nix`.

Pour comprendre ce qui tourne et où : le [README du repo](../../README.md), puis
[le cheatsheet](../cheatsheet.md).

## 1. Ton compte (Pocket-ID)

Tu reçois un mail d'invitation de `homelab@abe.lc`. Le lien t'amène sur https://auth.abe.lc
où tu crées une **passkey** : il n'y a pas de mot de passe. Ta passkey peut être ton
téléphone, ton gestionnaire de mots de passe (Bitwarden, 1Password…), Windows Hello, Touch ID
ou une clé de sécurité.

Ajoute une deuxième passkey tout de suite (téléphone et ordinateur, par exemple), depuis
https://auth.abe.lc. Si tu les perds toutes, tu peux demander un code de connexion par mail
sur la page de login, ou demander à Abel.

Ce compte sert partout : Headlamp, `kubectl`, Grafana, OpenBao. Ton compte est admin de tout
le cluster : protège-le comme tel.

## 2. Les interfaces web

| Quoi | Où | Accès |
|---|---|---|
| Console Kubernetes (Headlamp) | https://k8s.abe.lc | Internet |
| Page de statut (Gatus) | https://status.abe.lc | Internet |
| Dashboards, logs (Grafana) | https://grafana.int.abe.lc | VPN |
| Secrets (OpenBao) | https://bao.int.abe.lc, méthode *OIDC*, mount path `sso/oidc` | VPN |
| Traefik | https://traefik.int.abe.lc/dashboard/ | VPN |

Tout se connecte avec Pocket-ID. Headlamp suffit pour voir et modifier le cluster sans rien
installer.

## 3. En ligne de commande

### 3.1 Installer les outils

| Outil | À quoi il sert |
|---|---|
| `kubectl` | parler au cluster |
| `kubelogin` (plugin `oidc-login`) | ton login Pocket-ID pour `kubectl` |
| `flux` | voir et forcer les déploiements GitOps |
| Tailscale | le VPN : l'API Kubernetes et les interfaces `*.int` ne sont pas sur Internet |
| `sops`, `age` (plus tard) | les quelques secrets chiffrés dans git |
| `k9s` (optionnel) | une interface terminal pour le cluster |

- **macOS** : `brew install kubectl int128/kubelogin/kubelogin fluxcd/tap/flux k9s`, et
  l'app Tailscale depuis l'App Store.
- **Linux (Nix)** : `nix profile install nixpkgs#kubectl nixpkgs#kubelogin-oidc
  nixpkgs#fluxcd nixpkgs#k9s nixpkgs#tailscale` (attention : le paquet `kubelogin`
  tout court est celui d'Azure, ce n'est pas le bon).
- **Autre Linux / Windows** : `kubectl` depuis https://kubernetes.io/docs/tasks/tools/, le
  plugin avec [krew](https://krew.sigs.k8s.io) (`kubectl krew install oidc-login`), `flux`
  depuis https://fluxcd.io/flux/installation/, Tailscale depuis
  https://tailscale.com/download.

Vérifie : `kubectl oidc-login --help` doit répondre.

### 3.2 Le VPN (Tailscale)

Le serveur n'est pas celui de Tailscale mais le nôtre, `https://hs.abe.lc` (Headscale), et
le login est ton compte Pocket-ID.

- **Téléphone** : sur l'écran de connexion de l'app, menu `…` (iOS) ou `⋮` (Android) →
  *Use custom coordination server* / *Use an alternate server* → `https://hs.abe.lc`.
- **macOS** : clic sur l'icône de la barre de menus avec ⌥ Option → *Debug* → *Custom Login
  Server*. Pas à pas : https://hs.abe.lc/apple
- **Windows** : `tailscale login --login-server https://hs.abe.lc` (pas à pas :
  https://hs.abe.lc/windows).
- **Linux** : `sudo tailscale login --login-server https://hs.abe.lc --accept-routes`.

Tu as déjà un Tailscale à toi ? *Add account* (ou la commande `tailscale login` ci-dessus) :
notre tailnet devient un second profil, `tailscale switch` passe de l'un à l'autre. Sur
téléphone, un seul VPN peut être actif : coupe l'autre.

Il donne accès à l'API Kubernetes (`192.168.1.211:6443`) et aux interfaces internes
(`*.int.abe.lc`, `192.168.1.241`), rien d'autre. Il ne change pas le reste de ta connexion.

### 3.3 kubectl

Télécharge le kubeconfig ([kubeconfig.yaml](kubeconfig.yaml), il ne contient aucun secret) :

```bash
curl -fsSLo ~/.kube/homelab.yaml https://raw.githubusercontent.com/Orysse/homelab-cluster/main/docs/onboarding/kubeconfig.yaml
```

Puis, VPN allumé :

```bash
export KUBECONFIG=~/.kube/homelab.yaml
kubectl get nodes
flux get kustomizations
```

La première commande ouvre ton navigateur sur Pocket-ID ; après le login, le jeton est gardé
en cache (`~/.kube/cache/oidc-login`) et les commandes suivantes passent directement.

`kubectl auth whoami` doit afficher `oidc:<ton nom>` et le groupe `oidc:admins`.

## 4. Les règles du jeu

Le cluster est piloté par **git** (Flux) : le repo
[homelab-cluster](https://github.com/Orysse/homelab-cluster) décrit tout ce qui tourne, et
le cluster s'aligne sur lui.

- **Ce qui doit durer passe par git** : une pull request sur homelab-cluster. Un objet modifié
  à la main (`kubectl edit`) sur quelque chose que Flux gère est remis comme dans git au
  prochain passage (10 minutes au plus).
- **Pour tester, `kubectl apply` direct**, de préférence dans un namespace à toi : Flux ne
  touche pas à ce qu'il ne connaît pas.
- **Pas touche à la plateforme sans en parler** : `kube-system`, `flux-system`, `openbao`,
  `pocket-id`, `monitoring`, `cert-manager`, `metallb-system`, `external-secrets`. Si l'un
  d'eux casse, tout le monde perd l'accès (y compris toi).
- **Pas de secret en clair dans git** : le repo est public. Les secrets vont dans OpenBao (voir
  le README, section *Secrets*).

## En cas de souci

- `Unable to connect to the server` : le VPN n'est pas allumé (`tailscale status`), ou sous Linux
  `--accept-routes` manque.
- `Forbidden` : tu n'es pas encore dans le groupe `admins` (Abel), ou ton jeton date d'avant :
  `rm -rf ~/.kube/cache/oidc-login` puis relance la commande.
- Le navigateur ne s'ouvre pas : ouvre à la main l'URL `http://localhost:8000` affichée par
  la commande, sur la même machine.
- Pocket-ID est en panne : plus de login nulle part. Préviens Abel, il a un accès de secours.
