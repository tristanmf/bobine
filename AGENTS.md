# Bobine — notes pour les développeurs (humains ou IA)

- **Construire et installer** : `bash construire-app.sh` (Swift Package Manager, release, signature ad hoc,
  installe `~/Applications/Bobine.app`). macOS 15+, VLC dans `/Applications`, ffmpeg (Homebrew).
- **Langue** : interface, commentaires et noms en français.
- **Principes** : l'original n'est jamais modifié ; l'aperçu doit correspondre à l'export (mêmes calculs) ;
  rien n'est embarqué (VLC et ffmpeg sont ceux du Mac).
- **Moteurs** : `MoteurApple` lit un assemblage virtuel (`AVMutableComposition`) des morceaux gardés, en
  exposant les temps du fichier d'origine ; `MoteurVLCLecture` saute les passages supprimés (cible 20 ms après la
  coupure, sinon l'arrondi de VLC fait resauter en boucle). VLC est lancé avec `--no-sub-autodetect-file`
  (sinon il liste le dossier du fichier, ce que macOS peut bloquer, et reste « en ouverture »).
- **Journal** : `~/Library/Logs/Bobine.log` (sauts, espace, blocages).

## Auto-tests

`open -n --env BOBINE_AUTOTEST=<dossier> -a ~/Applications/Bobine.app <fichier>` écrit `<dossier>/autotest.log`
(montage simulé, exports, filtres, axe de la bande). Variables en plus :

| Variable | Test |
|---|---|
| `BOBINE_AUTOTEST_TRAVERSEE=1`, `debut`, ou `1.74-19.42,25-30@0` | la lecture traverse les passages supprimés (relevé toutes les 0,25 s) |
| `BOBINE_AUTOTEST_LECTURE=1` | reprise depuis un passage supprimé, retour au début |
| `BOBINE_AUTOTEST_LARGEUR=<points>` | fenêtre réduite, image de la barre d'outils |
| `BOBINE_AUTOTEST_ETAT=1` | état du moteur sans aucune commande |
| `BOBINE_AUTOTEST_FERMER=1` | l'accueil revient après fermeture de la fenêtre |
| `BOBINE_AUTOTEST_ACCUEIL=<png>` | image de la fenêtre d'accueil |
