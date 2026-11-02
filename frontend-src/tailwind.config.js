/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "../www/**/*.html",
    "../www/**/*.js"
  ],
  theme: {
    extend: {
      fontFamily: {
        sans: ["-apple-system", "BlinkMacSystemFont", "SF Pro Text", "Helvetica Neue", "Arial", "sans-serif"],
        mono: ["SF Mono", "ui-monospace", "SFMono-Regular", "Menlo", "monospace"]
      },
      boxShadow: {
        glass: "0 24px 60px rgba(0, 0, 0, .35)"
      },
      borderRadius: {
        "4xl": "2rem"
      },
      keyframes: {
        fadeUp: {
          "0%": { opacity: "0", transform: "translateY(6px)" },
          "100%": { opacity: "1", transform: "translateY(0)" }
        }
      },
      animation: {
        "fade-up": "fadeUp .28s ease-out both"
      }
    }
  },
  plugins: []
};
