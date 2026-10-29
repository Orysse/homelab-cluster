# Se connecter au homelab

Un compte Pocket-ID, Tailscale pour le réseau interne, puis `kubectl`. Compte une
vingtaine de minutes.

## 1. Ton compte

Tu reçois un mail d'invitation de `homelab@abe.lc`. Le lien t'amène sur https://auth.abe.lc,
où tu crées une **passkey**. Il n'y a pas de mot de passe : la passkey peut être ton
téléphone, ton gestionnaire de mots de passe, Windows Hello ou Touch ID. Ajoutes-en
une deuxième tout de suite depuis https://auth.abe.lc, pour ne pas dépendre d'un seul
appareil.

Ce compte sert partout. Ton groupe décide de tes droits :

| Groupe | Droits |
|---|---|
| `admins` | tout le cluster, Grafana, OpenBao (les secrets) |
| `visitors` | lecture seule, sans les secrets ([visite guidée](03-visiteur.md)) |

## 2. Le VPN (Tailscale)

L'API Kubernetes et les interfaces `*.int.abe.lc` ne sont pas sur Internet. Installe
[Tailscale](https://tailscale.com/download), puis connecte-le à **notre** serveur,
`https://hs.abe.lc`, et non à celui de Tailscale :

| Appareil | Comment |
|---|---|
| iPhone, iPad | écran de connexion de l'app → menu `…` → *Use custom coordination server* |
| Android | écran de connexion → menu `⋮` → *Use an alternate server* |
| macOS | icône de la barre de menus avec ⌥ Option → *Debug* → *Custom Login Server* ([pas à pas](https://hs.abe.lc/apple)) |
| Windows | `tailscale login --login-server https://hs.abe.lc` ([pas à pas](https://hs.abe.lc/windows)) |
| Linux | `sudo tailscale up --login-server https://hs.abe.lc --accept-routes` |

Le navigateur s'ouvre sur Pocket-ID. Sous Linux, `sudo tailscale set --operator=$USER`
évite le sudo pour les fois suivantes (`tailscale up` / `tailscale down`).

- **Tu as déjà un Tailscale à toi ?** *Add account* (ou la commande `tailscale login`
  ci-dessus) ajoute notre réseau comme un second profil. `tailscale switch` passe de l'un à
  l'autre.
- **Sur téléphone, un seul VPN à la fois** : coupe l'autre.

Pour vérifier : `tailscale status` liste `nuc1`, et https://home.int.abe.lc s'ouvre.

## 3. Les interfaces web

Toutes se connectent avec Pocket-ID.

| Quoi | Où | Réseau |
|---|---|---|
| Page d'accueil, état des services | https://home.int.abe.lc | VPN |
| Console Kubernetes (Headlamp) | https://k8s.abe.lc | Internet |
| Page de statut | https://status.abe.lc | Internet |
| Dashboards, logs, électricité (Grafana) | https://grafana.int.abe.lc | VPN |
| Secrets (OpenBao), admins | https://bao.int.abe.lc, méthode *OIDC*, mount path `sso` | VPN |
| Flux réseau (Hubble) | https://hubble.int.abe.lc | VPN |

Headlamp suffit pour voir et modifier le cluster sans rien installer.

## 4. kubectl

**Les outils** : `kubectl`, le plugin `oidc-login` ([kubelogin](https://github.com/int128/kubelogin),
qui fait le login Pocket-ID) et `flux`.

- **macOS** : `brew install kubectl int128/kubelogin/kubelogin fluxcd/tap/flux`
- **Nix** : `nix profile install nixpkgs#kubectl nixpkgs#kubelogin-oidc nixpkgs#fluxcd`. Le
  paquet `kubelogin` tout court est celui d'Azure, ce n'est pas le bon.
- **Ailleurs** (Debian, Kali, Windows…) : `kubectl` depuis https://kubernetes.io/docs/tasks/tools/,
  puis le plugin avec [krew](https://krew.sigs.k8s.io) (`kubectl krew install oidc-login`)
  ou le binaire des [releases](https://github.com/int128/kubelogin/releases), renommé
  `kubectl-oidc_login` dans ton `PATH`.

`kubectl oidc-login --help` doit répondre.

**Le kubeconfig** ne contient aucun secret :

```bash
mkdir -p ~/.kube/configs
curl -fsSLo ~/.kube/configs/homelab.yaml \
  https://raw.githubusercontent.com/Orysse/homelab-cluster/main/docs/onboarding/kubeconfig.yaml
export KUBECONFIG=$(ls -1d ~/.kube/config ~/.kube/configs/* 2>/dev/null | paste -sd:)
```

Mets la dernière ligne dans ton `~/.bashrc` ou `~/.zshrc` : tous les fichiers de
`~/.kube/configs/` deviennent des contextes, que `kubectx` sait choisir.

Puis, VPN allumé :

```bash
kubectl config use-context homelab
kubectl get nodes          # ouvre Pocket-ID dans le navigateur, une seule fois
kubectl auth whoami        # oidc:<toi>, groupe oidc:admins ou oidc:visitors
```

Le jeton est gardé dans `~/.kube/cache/oidc-login` et se renouvelle tout seul.

## 5. Les règles du jeu (admins)

Le cluster suit **git** : le repo [homelab-cluster](https://github.com/Orysse/homelab-cluster)
décrit tout ce qui tourne, et Flux aligne le cluster dessus.

- **Ce qui doit durer passe par une pull request** ([déployer une app](02-deployer-une-app.md)).
  Un objet géré par Flux et modifié à la main est remis comme dans git au passage suivant,
  10 minutes au plus.
- **Pour tester, `kubectl apply` direct**, de préférence dans un namespace à toi : Flux ne
  touche pas à ce qu'il ne connaît pas.
- **Pas touche à la plateforme sans en parler** : `kube-system`, `flux-system`, `openbao`,
  `pocket-id`, `pocket-id-operator`, `postgres`, `cnpg-system`, `gateway`, `headscale`,
  `monitoring`, `cert-manager`, `external-secrets`, `crowdsec`. Si l'un d'eux casse, tout
  le monde perd l'accès, toi compris.
- **Aucun secret en clair dans git** : le repo est public.

## En cas de souci

| Symptôme | Que faire |
|---|---|
| `Unable to connect to the server` | Tailscale n'est pas connecté (`tailscale status`), ou il manque `--accept-routes` sous Linux |
| `Forbidden` | ton groupe n'a pas ce droit, ou ton jeton date d'avant ton ajout au groupe : `rm -rf ~/.kube/cache/oidc-login` |
| `unknown command "oidc-login"` | le plugin n'est pas dans ton `PATH` |
| Le navigateur ne s'ouvre pas | ouvre à la main l'URL `http://localhost:8000` affichée, **sur la même machine** |
| Pocket-ID refuse l'accès à un service | ton groupe n'est pas autorisé sur ce client : demande à Abel |
| Pocket-ID est en panne | plus aucun login : préviens Abel, il a un accès de secours |
