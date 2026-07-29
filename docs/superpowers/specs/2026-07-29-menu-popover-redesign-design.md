# SimLease Menu Popover Redesign

## Goal

Make the menu popover a compact, status-first macOS utility. Simulator
availability must be understood immediately. Cleanup remains available but
visually secondary.

## Visual Thesis

Calm native macOS surface with strong left alignment, compact vertical rhythm,
and one semantic accent color. Green, orange, or red communicates status;
routine actions remain neutral.

## Content Hierarchy

1. Status header
   - Semantic SF Symbol
   - Primary status label
   - Short operational explanation
2. Leased details, when present
   - Owner and project
   - Elapsed time
   - Current command
   - Waiting count and every waiting thread
3. Secondary cleanup action
4. Compact footer actions
   - Copy Details
   - Refresh

Free state supporting copy is `Ready for simulator testing.` Error state shows
the exact metadata error. Existing leased metadata remains unchanged.

## Layout

- Keep the popover near 320 points wide.
- Let height follow visible content.
- Use a single leading alignment and consistent 8-12 point spacing.
- Separate status/details, cleanup, and footer actions with lightweight
  dividers.
- Render every waiting thread in a normal vertical stack. Do not hide names
  behind an internal scroll view.
- Keep each waiting thread on one line with middle truncation and a tooltip for
  the full name.
- Present cleanup as a full-width secondary row with a storage-related symbol.
- Group Copy Details and Refresh in one compact trailing footer.
- Do not add cards, gradients, decorative backgrounds, or another accent color.

## Interaction

- Opening behavior and two-second status refresh remain unchanged.
- Status changes use a short crossfade and SF Symbol replacement transition.
- Leased/error detail insertion and removal use the same restrained transition.
- Cleanup continues opening the existing separate review window.
- Copy Details and Refresh retain their current behavior.
- The content-sized menu window grows to show every waiting thread and shrinks
  again when the lease or waiter list changes.

## Accessibility

- Use native buttons for every action.
- Group status symbol, label, and explanation into one readable status element.
- Keep system text styles so content follows accessibility sizing.
- Preserve help text for truncated owner and command values.
- Preserve help text for truncated waiting-thread names.
- Keep clear accessible labels for waiting agents and cleanup.

## Scope

Change only `LeasePopoverView`, menu-extra content sizing, and tests directly
required by the new presentation. Do not change lease behavior, cleanup
behavior, status polling, menu-bar title, commands, or data models.

## Validation

- Existing menu view-model and display-state tests remain green.
- Add focused source or projection assertions for new supporting copy and
  hierarchy where practical.
- Build `SimLeaseMenuBar`.
- Package and install the app.
- Capture free, leased, and metadata-error popover screenshots for human visual
  review.
