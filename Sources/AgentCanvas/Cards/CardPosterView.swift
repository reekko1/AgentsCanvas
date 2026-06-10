import AppKit

/// What a card's poster face renders — built by `Card` from its accumulated
/// spine state, so the view stays a dumb arrangement of labels.
struct PosterModel {
    let statusLine: String        // "✦2 · BLOCKED · 14m"
    let statusColor: NSColor
    let headline: String          // the task label, or the folder name pre-prompt
    let todos: [AgentTodo]        // the plan — rendered as a ✓/▸/○ checklist
    let body: String?             // live action line / done summary / what it wants
    let bodyColor: NSColor
}

/// A card's far-zoom LOD: when the terminal has shrunk to unreadable mush, the
/// card becomes album art — big status, the task in poster type, the agent's
/// own checklist, and the one line that matters for the current state. Swapped
/// in/out by `Card` from the controller's magnification.
///
/// The type is **zoom-compensated**: `setScale(≈1/magnification)` grows fonts,
/// spacing, and padding in document units so the poster reads at a constant
/// on-screen size as the camera pulls back — and sheds its lower-priority rows
/// (body, then the checklist) as they'd no longer fit, down to the irreducible
/// status + headline.
///
/// Lives inside `ItemContainerView`'s content area on the magnified canvas, so
/// it follows the layout discipline: Auto Layout only (font/constraint-constant
/// changes and `NSStackView` show/hide are the sanctioned moves).
final class CardPosterView: NSView {
    override var isFlipped: Bool { true }

    private let statusLabel = NSTextField(labelWithString: "")
    private let headlineLabel = NSTextField(wrappingLabelWithString: "")
    /// Fixed pool of checklist rows (text + hidden toggled at render — no
    /// subview churn inside the magnified canvas). Sized by the largest tier's
    /// row budget, so a budget change can never silently truncate.
    private let todoRowLabels: [NSTextField] =
        (0..<CanvasLayout.posterRowBudgets.dense).map { _ in NSTextField(labelWithString: "") }
    private let todoStack = NSStackView()
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    private var padConstraints: [NSLayoutConstraint] = []   // top, leading, trailing

    private var scale: CGFloat = 1
    private var model: PosterModel?
    private var contentWidth: CGFloat = 0   // card content width, pre-padding

    // Simplification tiers: what still earns its space at this scale
    // (cutoffs + budgets are tunables in CanvasLayout).
    private var showsBody: Bool { scale < CanvasLayout.posterBodyCutoff }
    private var showsTodos: Bool { scale < CanvasLayout.posterTodosCutoff }
    /// How many checklist rows fit before collapsing (done → "✓ n done",
    /// overflow → "… n more") — fewer as the type grows.
    private var todoRowBudget: Int {
        let budgets = CanvasLayout.posterRowBudgets
        if scale < CanvasLayout.posterDenseCutoff { return budgets.dense }
        return scale < CanvasLayout.posterBodyCutoff ? budgets.mid : budgets.tight
    }

    init() {
        super.init(frame: .zero)

        statusLabel.lineBreakMode = .byTruncatingTail

        headlineLabel.textColor = Theme.colors.termText
        headlineLabel.lineBreakMode = .byTruncatingTail
        headlineLabel.isSelectable = false

        todoStack.orientation = .vertical
        todoStack.alignment = .leading
        for label in todoRowLabels {
            label.lineBreakMode = .byTruncatingTail
            label.isHidden = true
            todoStack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: todoStack.widthAnchor).isActive = true
        }

        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.isSelectable = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [statusLabel, headlineLabel, todoStack, bodyLabel] {
            stack.addArrangedSubview(v)
            // Wrapping labels need their width pinned to wrap instead of growing the stack.
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        addSubview(stack)

        let top = stack.topAnchor.constraint(equalTo: topAnchor)
        let leading = stack.leadingAnchor.constraint(equalTo: leadingAnchor)
        let trailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        padConstraints = [top, leading, trailing]
        NSLayoutConstraint.activate([
            top, leading, trailing,
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        applyScale()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Apply a zoom-compensation factor (quantized by `Card` so a camera fly
    /// re-layouts a handful of times, not per frame). Re-renders the current
    /// model: tier visibility depends on the scale.
    func setScale(_ s: CGFloat) {
        guard abs(s - scale) > 0.01 else { return }
        scale = s
        applyScale()
        if let model { apply(model) }
    }

    /// Push the current scale into every scale-dependent property (fonts,
    /// spacing, padding, line caps). Also init's one-time styling pass.
    private func applyScale() {
        statusLabel.font = Theme.fonts.posterStatus(scale)
        headlineLabel.font = Theme.fonts.posterHeadline(scale)
        for label in todoRowLabels { label.font = Theme.fonts.posterTodo(scale) }
        bodyLabel.font = Theme.fonts.posterBody(scale)
        headlineLabel.maximumNumberOfLines = scale >= CanvasLayout.posterBodyCutoff ? 2 : 3
        bodyLabel.maximumNumberOfLines = scale >= CanvasLayout.posterDenseCutoff ? 2 : 4
        stack.spacing = 14 * scale
        stack.setCustomSpacing(20 * scale, after: headlineLabel)
        stack.setCustomSpacing(20 * scale, after: todoStack)
        todoStack.spacing = 7 * scale
        let pad = CanvasLayout.posterPadding * scale
        padConstraints[0].constant = pad
        padConstraints[1].constant = pad
        padConstraints[2].constant = -pad
        applyWrapWidth()
    }

    /// Pin the wrapping labels' layout width. Set from `Card` whenever the
    /// card's frame is known/changes — wrapping labels compute a wrong intrinsic
    /// height without it, and guessing inside the magnified canvas is how layout
    /// loops start. `w` is the card's content width; the (scaled) poster padding
    /// is subtracted here, where the scale is known.
    func setLayoutWidth(_ w: CGFloat) {
        contentWidth = w
        applyWrapWidth()
    }

    private func applyWrapWidth() {
        let inner = max(50, contentWidth - 2 * CanvasLayout.posterPadding * scale)
        headlineLabel.preferredMaxLayoutWidth = inner
        bodyLabel.preferredMaxLayoutWidth = inner
    }

    func render(_ m: PosterModel) {
        model = m
        apply(m)
    }

    private func apply(_ m: PosterModel) {
        statusLabel.stringValue = m.statusLine
        statusLabel.textColor = m.statusColor
        headlineLabel.stringValue = m.headline

        let rows = showsTodos ? checklistRows(m.todos) : []
        for (i, label) in todoRowLabels.enumerated() {
            if i < rows.count {
                label.stringValue = rows[i].text
                label.textColor = rows[i].active ? Theme.colors.termText : Theme.colors.termMuted
                label.isHidden = false
            } else {
                label.isHidden = true
            }
        }
        todoStack.isHidden = rows.isEmpty

        bodyLabel.stringValue = m.body ?? ""
        bodyLabel.isHidden = (m.body == nil) || !showsBody
        bodyLabel.textColor = m.bodyColor
    }

    /// The plan as display rows, collapsed to the row budget: every title when
    /// it fits; otherwise done items fold into "✓ n done" and the tail into
    /// "… n more", keeping the in-progress row (the one that matters) visible.
    private func checklistRows(_ todos: [AgentTodo]) -> [(text: String, active: Bool)] {
        guard !todos.isEmpty else { return [] }
        func row(_ t: AgentTodo) -> (text: String, active: Bool) {
            if t.isDone { return ("✓ \(t.content)", false) }
            if t.isActive { return ("▸ \(t.activeForm ?? t.content)", true) }
            return ("○ \(t.content)", false)
        }
        let budget = todoRowBudget
        if todos.count <= budget { return todos.map(row) }

        var rows: [(text: String, active: Bool)] = []
        let doneCount = todos.filter(\.isDone).count
        if doneCount > 0 { rows.append(("✓ \(doneCount) done", false)) }
        let open = todos.filter { !$0.isDone }
        let slots = max(1, budget - rows.count - 1)   // reserve the "… n more" line
        if open.count > slots {
            rows += open.prefix(slots).map(row)
            rows.append(("… \(open.count - slots) more", false))
        } else {
            rows += open.map(row)
        }
        return rows
    }
}
