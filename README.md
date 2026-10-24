# VYRO — Make every frame hit.

Éditeur vidéo mobile spécialisé gaming edit. iPhone / Swift / SwiftUI / AVFoundation.

## Phase 1 — Squelette fonctionnel MVP

Ce dépôt contient le code source Swift de la Phase 1 (dossier VYRO-Sources/) :
interface sombre VYRO, écran d'accueil avec liste de projets, éditeur avec
import de clip (Photos), lecture AVPlayer avec tête de lecture, modèle de
projet versionné (schemaVersion) et sauvegarde locale JSON.

## Mise en place dans Xcode (une seule fois)

1. Ouvrir Xcode, File > New > Project, iOS > App, Next.
   - Product Name : VYRO
   - Interface : SwiftUI — Language : Swift
   - Storage : None
2. Choisir l'emplacement : LE dossier vyro cloné (le projet est créé DANS ce dossier).
   ATTENTION : décocher "Create Git repository" (il existe déjà).
3. Dans le navigateur Xcode (colonne de gauche) :
   - Supprimer ContentView.swift ET VYROApp.swift du template, Move to Trash.
   - Glisser le dossier VYRO-Sources dans le navigateur :
     - "Copy items if needed" : DECOCHE (les fichiers restent versionnés par git),
     - Cocher la target VYRO.
4. Target VYRO, General, Minimum Deployments : iOS 16.0.
5. Brancher l'iPhone, sélectionner ton appareil comme destination, Cmd+R.

## Premier commit du projet Xcode

    cd vyro
    git add VYRO.xcodeproj VYRO-Sources README.md .gitignore
    git commit -m "Ajout projet Xcode + squelette Phase 1"
    git push

## Validation Phase 1 (checklist)

- [ ] L'app se lance sans planter.
- [ ] Le bouton + crée un projet et ouvre l'éditeur.
- [ ] L'icône d'import ouvre la photothèque filtrée sur les vidéos.
- [ ] Un clip importé s'affiche dans l'aperçu et se lit.
- [ ] La tête de lecture suit la lecture ; le slider permet de naviguer.
- [ ] La durée s'affiche ; l'heure se met à jour.
- [ ] Le projet apparaît dans la liste d'accueil après retour.
- [ ] Un clip illisible affiche un message d'erreur compréhensible.

## Structure du code

- VYROApp.swift        : Point d'entrée SwiftUI, thème sombre
- Theme.swift          : Couleurs et identité visuelle VYRO
- Models.swift         : Project / Track / Clip / Effect / Keyframe (Codable, versionné)
- ProjectStore.swift   : Sauvegarde/chargement JSON + gestion des médias
- MediaImporter.swift  : Sélecteur PHPicker (vidéos uniquement), copie locale
- EditorViewModel.swift: Logique : AVPlayer, durée, tête de lecture, erreurs
- EditorView.swift     : Éditeur : aperçu, contrôles de lecture, import
- HomeView.swift       : Accueil : liste des projets, création

## Prochaines phases

Phase 2 : zoom exportable (pipeline AVVideoComposition partagé préview/export).
