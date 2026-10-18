# Accessibility

The interface includes accessible names, values and units, control states, announcements, and keyboard operations. **Keyboard Annotations** (**⇧⌘K**) supports creation, editing, deletion, and adjustment of coordinates and dimensions, with undo. Open the **Tools** catalog with **⇧⌘T**. These are the English control names; interface text and accessibility labels follow the selected [app language](LOCALIZATION.md).

## Available checks

Static review and native tests are documented in [AccessibilityPanelAudit](../Development/AccessibilityPanelAudit.json), `CartaAccessibilityTests`, and `CartaKeyboardEditingTests`. These checks cover interface behavior supported by the code and do not replace a complete session using assistive technologies.

**The complete manual VoiceOver audit has not been completed.** A brief activation of VoiceOver is not presented as a passed audit. The technical status remains `manual_verification_pending` in the [feature report](../Development/FeatureVerification.json).

Physical scanner use, authorized screen capture, and speech playback require additional tests on real devices. No general conformity of the interface to an accessibility standard is claimed.

## Accessibility of PDF documents

Generating page-level tags, language information, and descriptions does not automatically reconstruct the content's complete semantic structure. ParentTree/MCID and structure attribute checks verify modeled relationships without attesting human meaning, reading order, or PDF/UA conformity.

## Report a problem

Include the macOS and CartaPDF versions, assistive technology and relevant settings, affected control, key sequence, and expected and observed behavior. Use a synthetic PDF without personal information. See [SUPPORT](../SUPPORT.md) for reporting instructions.
