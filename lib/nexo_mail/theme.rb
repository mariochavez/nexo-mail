# frozen_string_literal: true

module NexoMail
  # Catppuccin theming for the terminal UI (lipgloss palette) and the digest
  # markdown (Glamour style JSON). Light (latte) + dark (frappe/macchiato/mocha).
  module Theme
    DEFAULT = "mocha"

    # lipgloss palette per flavor — semantic keys used by the CLI's UI styles.
    PALETTES = {
      "mocha" => {mauve: "#cba6f7", green: "#a6e3a1", red: "#f38ba8", peach: "#fab387", overlay1: "#7f849c", base: "#1e1e2e", text: "#cdd6f4"},
      "latte" => {mauve: "#8839ef", green: "#40a02b", red: "#d20f39", peach: "#fe640b", overlay1: "#8c8fa1", base: "#eff1f5", text: "#4c4f69"},
      "frappe" => {mauve: "#ca9ee6", green: "#a6d189", red: "#e78284", peach: "#ef9f76", overlay1: "#838ba7", base: "#303446", text: "#c6d0f5"},
      "macchiato" => {mauve: "#c6a0f6", green: "#a6da95", red: "#ed8796", peach: "#f5a97f", overlay1: "#8087a2", base: "#24273a", text: "#cad3f5"}
    }.freeze

    module_function

    def flavors = PALETTES.keys

    # Map an arbitrary flavor name onto a known one (fallback to the default).
    def resolve(flavor)
      f = flavor.to_s.downcase
      PALETTES.key?(f) ? f : DEFAULT
    end

    def palette(flavor) = PALETTES.fetch(resolve(flavor))

    def glamour_style(flavor)
      JSON.parse(File.read(File.join(NexoMail::DATA_DIR, "themes", "catppuccin_#{resolve(flavor)}.json")))
    end
  end
end
