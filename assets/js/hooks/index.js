// The LiveView hooks `app.js` registers, one module each. A hook's name here is
// the value its `phx-hook` attribute carries, so adding one means adding it to
// both this object and the template that mounts it.
import {AutoDismiss} from "./auto_dismiss"
import {ChatDismiss} from "./chat_dismiss"
import {ChatInput} from "./chat_input"
import {ChatScroll} from "./chat_scroll"
import {DialogFocus} from "./dialog_focus"
import {DropdownExpanded} from "./dropdown_expanded"
import {EscapeStaysInSelect} from "./escape_stays_in_select"
import {ThemeToggle} from "./theme_toggle"

export const Hooks = {
  AutoDismiss,
  ChatDismiss,
  ChatInput,
  ChatScroll,
  DialogFocus,
  DropdownExpanded,
  EscapeStaysInSelect,
  ThemeToggle
}
