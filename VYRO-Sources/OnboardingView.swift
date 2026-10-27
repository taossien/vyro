//
//  OnboardingView.swift
//  Accueil du premier lancement : trois pages pour comprendre VYRO en dix secondes.
//

import SwiftUI

struct OnboardingView: View {
    var onFinish: () -> Void
    @State private var page = 0

    private let pages: [(icon: String, title: String, text: String)] = [
        ("film.stack", "Importe tes clips de jeu",
         "Choisis une ou plusieurs vidéos. VYRO les assemble et prépare le montage."),
        ("wand.and.stars", "Choisis un style, ajoute ta musique",
         "Un style place zooms, flashs, glitchs et sons exactement sur le rythme. Tout reste modifiable ensuite."),
        ("square.and.arrow.up", "Exporte et publie",
         "Format vertical, 1080p, 60 images par seconde si tu veux des effets ultra fluides.")
    ]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Text("VYRO")
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundColor(.white)
                Text("Make every frame hit.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.accent)
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        VStack(spacing: 14) {
                            Image(systemName: item.icon)
                                .font(.system(size: 54))
                                .foregroundColor(Theme.accent)
                            Text(item.title)
                                .font(.title3.weight(.bold))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                            Text(item.text)
                                .font(.callout)
                                .foregroundColor(Theme.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .frame(height: 260)
                Button {
                    if page < pages.count - 1 { withAnimation { page += 1 } } else { onFinish() }
                } label: {
                    Text(page < pages.count - 1 ? "Suivant" : "C'est parti")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accent))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 28)
                Button("Passer", action: onFinish)
                    .font(.footnote)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }
        }
    }
}
