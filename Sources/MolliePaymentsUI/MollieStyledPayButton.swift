#if canImport(UIKit)
    import UIKit

    /// Themed pay button surfaced by `MollieCardFormViewController`. Wraps a
    /// `UIButton` so we can swap its title for an inline spinner + "Processing…"
    /// label while the host coordinator is in flight, without losing the
    /// rounded chrome or theme tokens applied via `applyTheme(_:)`.
    ///
    /// The wrapper deliberately exposes `setTitle`, `setLoading`, `isEnabled`,
    /// and an `onTap` callback rather than the underlying button so the form
    /// VC never has to reach into a private subview to drive state.
    @MainActor
    package final class MollieStyledPayButton: UIView {
        package var onTap: (() -> Void)?

        private let button: UIButton = {
            let btn = UIButton(type: .custom)
            btn.translatesAutoresizingMaskIntoConstraints = false
            return btn
        }()

        private let spinner: UIActivityIndicatorView = {
            let view = UIActivityIndicatorView(style: .medium)
            view.color = .white
            view.translatesAutoresizingMaskIntoConstraints = false
            view.hidesWhenStopped = true
            return view
        }()

        private let processingLabel: UILabel = {
            let label = UILabel()
            label.text = "Processing…"
            // Initial colour + font here are placeholders; `applyTheme(_:)`
            // overrides both with the merchant-configured `onPrimary` token
            // and the typography-driven button font. Without those defaults
            // the label would still render at a sane size if a host forgot
            // to call the applier before showing the button.
            label.textColor = .white
            label.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isHidden = true
            return label
        }()

        /// Last-known title set via `setTitle(_:)`. Tracked so `setLoading(false)`
        /// can restore the user-facing label after a loading run; without this
        /// the button would come back empty.
        private var storedTitle: String?

        private var isLoading = false

        package init() {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            setupLayout()
            button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("MollieStyledPayButton does not support NSCoder")
        }

        private func setupLayout() {
            addSubview(button)
            addSubview(spinner)
            addSubview(processingLabel)

            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: topAnchor),
                button.bottomAnchor.constraint(equalTo: bottomAnchor),
                button.leadingAnchor.constraint(equalTo: leadingAnchor),
                button.trailingAnchor.constraint(equalTo: trailingAnchor),
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),

                spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
                spinner.trailingAnchor.constraint(equalTo: processingLabel.leadingAnchor, constant: -8),

                processingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                processingLabel.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 14),
            ])
        }

        package func setTitle(_ title: String) {
            storedTitle = title
            // While loading we deliberately keep the visible title blank so the
            // spinner + "Processing…" label own the chrome; the title is
            // restored when `setLoading(false)` fires.
            if !isLoading {
                button.setTitle(title, for: .normal)
            }
        }

        package func setLoading(_ loading: Bool) {
            isLoading = loading
            isUserInteractionEnabled = !loading
            // Belt-and-braces: also flip `isEnabled` so a UIKit-level event
            // (e.g. a stray hit-test from an in-flight gesture recogniser)
            // can't race past the `isUserInteractionEnabled` flag and fire
            // a second tap while the host coordinator is mid-tokenisation.
            if loading {
                button.isEnabled = false
            }

            if loading {
                UIView.animate(withDuration: 0.15) {
                    self.button.setTitle(nil, for: .normal)
                    self.button.setTitle(nil, for: .disabled)
                    self.spinner.startAnimating()
                    self.processingLabel.isHidden = false
                }
            } else {
                UIView.animate(withDuration: 0.15) {
                    self.spinner.stopAnimating()
                    self.processingLabel.isHidden = true
                }
                // Restoring the title under an in-flight UIView animation
                // makes UIButton's titleLabel cross-fade through a transparent
                // intermediate state — visually a "flash to blank then snap
                // back". Apply the title outside the animation transaction
                // so the label appears at full opacity immediately.
                UIView.performWithoutAnimation {
                    self.button.setTitle(self.storedTitle, for: .normal)
                    self.button.layoutIfNeeded()
                }
            }
        }

        package func applyTheme(_ theme: MollieAppearance) {
            button.backgroundColor = theme.colors.primary.uiColor
            button.layer.cornerRadius = theme.cornerRadius
            button.layer.masksToBounds = true
            let onPrimary = theme.colors.onPrimary.uiColor
            button.setTitleColor(onPrimary, for: .normal)
            button.setTitleColor(onPrimary.withAlphaComponent(0.5), for: .disabled)
            let buttonFont = UIFont.systemFont(
                ofSize: CGFloat(theme.typography.buttonFontSize),
                weight: .semibold
            )
            button.titleLabel?.font = buttonFont
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            // Keep the inline "Processing…" label in lockstep with the title:
            // same `onPrimary` foreground, same typography-driven font, and
            // Dynamic Type opt-in. Without this, `applyTheme` would silently
            // ignore merchant overrides for the loading-state label.
            processingLabel.textColor = onPrimary
            processingLabel.font = buttonFont
            processingLabel.adjustsFontForContentSizeCategory = true
            spinner.color = onPrimary
        }

        package var isEnabled: Bool {
            get { button.isEnabled }
            set {
                button.isEnabled = newValue
                UIView.animate(withDuration: 0.1) {
                    self.button.alpha = newValue ? 1.0 : 0.5
                }
            }
        }

        /// Exposes the inner button's background color for theme-applier tests
        /// that need to assert `applyTheme` wrote the correct primary color.
        package var buttonBackgroundColor: UIColor? {
            button.backgroundColor
        }

        /// Exposes the inner button's title color for the given control state.
        /// Used by theme tests to assert that `applyTheme` honours
        /// `Colors.onPrimary` instead of a hardcoded white.
        package func titleColorForTesting(state: UIControl.State) -> UIColor? {
            button.titleColor(for: state)
        }

        /// Exposes the processing label's current font + colour so theme
        /// tests can verify that `applyTheme` drives them — earlier
        /// versions of this view set them once at init and ignored
        /// subsequent theme changes.
        package var processingLabelFontForTesting: UIFont {
            processingLabel.font
        }

        package var processingLabelTextColorForTesting: UIColor? {
            processingLabel.textColor
        }

        /// Forwards a tap from a test directly to the registered `onTap`
        /// callback. Mirrors `UIButton.sendActions(for: .touchUpInside)` so
        /// existing tests that drove the old `submitButton` keep working
        /// against the new wrapper.
        package func sendTapForTesting() {
            handleTap()
        }

        @objc private func handleTap() {
            onTap?()
        }
    }
#endif
