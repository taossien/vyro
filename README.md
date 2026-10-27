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

### Sous-titres automatiques
- Outil Texte : transcription de la voix du montage (reconnaissance vocale d'Apple, sur l'appareil quand c'est possible), en français ou en anglais.
- Les mots horodatés sont regroupés en sous-titres courts (4 mots au plus), chacun étant un texte modifiable de la piste Texte. Style, police et couleur réglables pour tous d'un coup.
- Import d'une vidéo depuis Fichiers (en plus de la photothèque).
- Limites connues : la qualité dépend de la netteté de la voix (la musique forte couvre la parole) ; pas encore de mise en avant du mot prononcé.

## Étincelles, anneau, aberration, image figée, rediffusion

- **Étincelles / Anneau** (`Overlays.swift`) : effets dessinés en superposition, avant les textes. **Aberration** : séparation RVB à l'impact.
- **Figer l'image** (bouton pause dans la barre des clips) : insère un clip « hold » de 0,8 s sur l'image sous la tête de lecture ; tout ce qui suit (effets, textes, images clés, sons) est décalé.
- **Rejouer au ralenti** (bouton flèche circulaire) : rejoue les 0,5 s précédentes à 50 %, avec flash, petit zoom et whoosh.
- Limite : tête de lecture à plus de 0,5 s du début du clip pour la rediffusion. Non testé sur iPhone.

## Presets de zoom et de vitesse

- **Smash** : zoom 1,7 en 0,3 s (courbe Claque) + secousse + aberration. **Hole** : plongée 2,1 sur 1,1 s (courbe Douce) + halo + aberration. Chaque effet reste modifiable.
- Vitesse : **Hero time** (accélère, ralenti net x0,2 sur l'impact, repart) et **Ralenti doux** (x0,5 sur 1 s).

## Sous-titres karaoké

Option « Karaoké » dans les sous-titres automatiques : phrases de 4 mots, le mot prononcé passe en jaune (blanc si le texte est jaune). Les débuts de mots sont stockés dans `TextOverlay.wordStarts`.

## Transitions (15)

Flash, Zoom, Glitch, Flou, Noir, Whip, puis Spin, Glissé, Strobe, Flash zoom, Tremble, Glitch+, Whip V, Punch, Roulis. Toutes sont calculées dans `FrameRenderer.state` (échelle, décalage, rotation, flou, flash), sans filtre supplémentaire.

## Textes, export, son, partage, accueil

- **Textes** : styles Carte, 3D, Glitch, Feu, Rétro (en plus de Simple, Contour, Fond, Néon) et animation « Mots » (les mots apparaissent un à un).
- **Export** : nouveau préréglage « 1080p 60 i/s » (cadence forcée à 60, effets plus fluides, fichier plus lourd).
- **Musique** : elle baisse automatiquement (45 %) pendant les sous-titres, donc la voix passe au premier plan.
- **Styles partageables** (`StyleTemplate.swift`) : « Partager mon style » exporte effets, sons, look, flou et transition dans un fichier JSON ; « Importer un style » l'applique à un autre montage en étirant les temps à sa durée.
- **Accueil** (`OnboardingView.swift`) : trois pages au premier lancement (clé `vyro.onboarded`).

## Icône et volume des clips

- **Icône** : `Assets.xcassets/AppIcon.appiconset/AppIcon.png` (V néon avec étincelle), branchée via `ASSETCATALOG_COMPILER_APPICON_NAME`.
- **Égalisation du son d'origine** : avec plusieurs clips, le niveau RMS de chacun est mesuré (20 premières secondes) et ramené vers la médiane (gain borné 0,6 à 1,6). Automatique ; non écouté sur appareil.

## Look Cinématique

Nouveaux réglages d'étalonnage (tous optionnels, anciens projets inchangés) : **Teinte ciné** (ombres bleu-vert, lumières orangées), **Pellicule** (noirs relevés), **Grain** animé, **Halo** sur les lumières, **Bandes** noires. Préréglage « Cinématique » dans Look (utilisé par le style Cinéma). Le grain est volontairement discret (12 %) : à valider sur iPhone.
