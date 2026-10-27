# VYRO — Make every frame hit.

Éditeur vidéo mobile pensé pour les gaming edits. iPhone, Swift, SwiftUI, AVFoundation. iOS 16+.

## Ce que fait l'app

- Import d'un clip depuis la photothèque, lecture, tête de lecture, projets sauvegardés en local (JSON versionné).
- **Zoom** : effet "punch" (montée rapide, retour doux), début, durée et intensité réglables.
- **Shake** : secousse déterministe (seed fixe), identique à chaque lecture et à l'export.
- **Vitesse** constante de x0.25 à x4 (audio conservé).
- **Stabilisation** : analyse du mouvement (Vision), on retire les tremblements et on garde les mouvements voulus ; léger recadrage.
- **Export** en MP4 avec exactement le même pipeline que l'aperçu, puis partage / enregistrement dans Photos.

## Lancer le projet

1. Ouvrir `VYRO.xcodeproj` dans Xcode.
2. Choisir un iPhone (réel de préférence) et lancer (Cmd+R).

Important : le rendu des effets (zoom, shake, stabilisation, export) utilise les compositions vidéo
d'AVFoundation. Le simulateur iOS 27.0 ne sait pas les lire (erreur -12784) ni décoder les images
(`Cannot Decode`). Teste donc sur un iPhone réel. En build Debug, un bouton "Charger un clip de test"
génère un clip synthétique avec un tremblement connu.

## Structure du code (VYRO-Sources/)

| Fichier | Rôle |
| --- | --- |
| VYROApp.swift | Point d'entrée, thème sombre |
| Theme.swift | Couleurs, formats de temps |
| Models.swift | Project / Track / Clip / Effect (Codable, versionné) |
| ProjectStore.swift | Sauvegarde JSON, médias, données de stabilisation |
| MediaImporter.swift | Sélecteur de vidéos (PHPicker), copie locale |
| Effects.swift | Effets déterministes (zoom, shake) et données de stabilisation |
| VideoPipeline.swift | Pipeline unique aperçu + export (vitesse, instructions de cadrage) |
| StabilizationAnalyzer.swift | Analyse Vision, lissage, correction |
| EditorViewModel.swift | Logique de l'éditeur |
| EditorView.swift | Interface de l'éditeur |
| HomeView.swift | Accueil et liste des projets |
| DemoClip.swift | Clip de test (Debug uniquement) |

## Checklist de validation sur iPhone

- [ ] Import d'un clip, lecture, tête de lecture.
- [ ] Ajout d'un Zoom : l'aperçu zoome à l'instant voulu, les réglages agissent en direct.
- [ ] Ajout d'un Shake : même secousse à chaque lecture.
- [ ] Vitesse x0.5 / x2 : durée et son cohérents.
- [ ] Stabilisation sur un clip qui tremble : image plus calme, mouvements voulus conservés.
- [ ] Export : la vidéo exportée est identique à l'aperçu (effets aux mêmes instants).

## Suite

Validation terrain avec 20 à 30 gaming editors, puis TestFlight (compte Apple Developer requis, environ 99 $/an).

## Ajouts récents

- Effets : Zoom (courbes punch / doux / claque), Shake, Glitch (saccades), Flash blanc.
- Découpe du clip (début / fin), rampes de vitesse, stabilisation.
- Musique : import d'un morceau, détection des temps forts (BeatAnalyzer), aimantation des effets, zoom automatique sur les temps.
- Export : Original, 1080p, 720p.
- Annuler / rétablir, dupliquer un effet.

Tous ces rendus (effets, découpe, musique, export) sont à valider sur un vrai iPhone : le simulateur iOS 27 ne lit pas les compositions vidéo.
Limites connues : un seul clip par montage, effets positionnés en temps de montage (ils ne suivent pas une découpe), Glitch sans séparation RVB.

### Montage multi-clips
- Scinder un clip à la tête de lecture, ajouter des clips à la suite, les supprimer, les déplacer (gauche/droite).
- Vitesse, découpe et stabilisation propres à chaque clip ; effets, musique et flou de mouvement globaux sur tout le montage.
- Les clips de format différent remplissent le format du premier clip (cadrage centré).
- Limites connues : pas encore de transitions entre clips ; à valider sur un vrai iPhone (vidéos verticales, performances).

### Texte et sous-titres
- Outil Texte : plusieurs textes, début et durée, taille, hauteur, 4 styles (simple, contour, fond, néon), 6 couleurs, animation (pop, fondu).
- Outil Look : étalonnage (presets Néon, Cinéma, Sombre, Vif, Rétro + réglages).
- Les textes ont leur piste sur la timeline (toucher, glisser) et 6 polices au choix.

### Mouvement (images clés)
- Piste Mouvement : images clés de zoom, position et rotation, avec une courbe (lisse, linéaire, rapide, maintenu) vers l'image clé suivante.
- Le flou de mouvement s'applique aussi aux mouvements créés avec les images clés.

### Projets et export
- Miniature et nombre de clips pour chaque projet sur l'accueil.
- Bouton « Enregistrer dans Photos » à la fin de l'export (autorisation d'ajout à la photothèque), en plus du partage.

### Transitions
- Outil Transition : sur la coupure d'entrée d'un clip, au choix flash, zoom, glitch, flou, noir ou whip, avec une durée réglable (0,1 à 1 s).
- Ce sont des effets de coupure (centrés sur la coupe, sans fondu enchaîné) : chaque image vient d'un seul clip, ce qui garde l'aperçu fluide.
