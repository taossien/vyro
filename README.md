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
