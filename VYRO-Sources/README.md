
## Mode simple, styles et accueil guidé
- Par défaut l'éditeur est en **mode simple** : Impact, Style, Couper, Vitesse, Texte, Look, Musique. La baguette en haut bascule en **mode avancé** (Zoom, Shake, Glitch, Flash, Halo, Stable, Transition, Mouvement, Rendu). Réglage mémorisé (`vyro.advanced`).
- **Styles** (`Styles.swift`) : Néon, Cinéma, Ultra rapide, Impact. Un toucher pose look, effets sur les temps forts (ou à intervalles réguliers sans musique), transitions et flou. « Retirer le style » annule.
- **Accueil guidé** : bouton « Importer mes clips » quand le projet est vide, puis 3 étapes (Style, Musique, Exporter).
- Import multi-sélection depuis Photos.
- Styles ajoutés d'après des edits Fortnite de référence : **Sombre** (look froid contrasté, zooms secs, aberration chromatique, balayage) et **Lueur** (couleurs vives, halos, flashs doux). Les styles sont des points de départ : chaque effet reste modifiable.
- Sous-titres : choix **Phrases** ou **Mot par mot**.
- Texte : curseur **Angle** (-45° à +45°) et animation **Tourne** (pop avec rotation).
- Mode simple : la timeline n'affiche que 3 pistes (effets, vitesse, texte) pour laisser de la place aux panneaux.

## Design sonore
- 6 effets sonores originaux (whoosh, whoosh vif, impact, basse, riser, glitch) générés par `tools/make_sounds.py` (synthèse, sans droits) dans `VYRO-Sources/Sounds/`.
- Panneau **Sons** : poser un son à la tête de lecture, volume et instant réglables, « sur chaque temps fort », tout retirer. Piste sonore sur la timeline.
- Les styles posent aussi un son sur chaque temps fort retenu (Néon : whoosh vif, Cinéma : basse, Ultra rapide : glitch, Impact et Sombre : impact, Lueur : whoosh).
- Moteur : une piste audio par son dans la composition, ce qui permet les chevauchements (max 60). Le riser et le whoosh démarrent avant l'instant choisi pour tomber sur le coup.
