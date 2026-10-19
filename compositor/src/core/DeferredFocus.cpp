#include "DeferredFocus.hpp"

namespace gf::deferredfocus {

    bool mustWait(const Refusal& refusal) {
        return refusal.locked || refusal.exclusive || refusal.holderKeeps;
    }

    FocusOrigin focusOrigin(FocusCause cause, bool wasLastFocused, bool pressed) {
        switch (cause) {
            case FocusCause::Click: return pressed ? FocusOrigin::UserChoice : FocusOrigin::CursorRefocus;
            case FocusCause::KeyBinding:
            case FocusCause::FocusDispatch:
            case FocusCause::GroupDispatch:
            case FocusCause::Activation:
            case FocusCause::SwitchSoft:
            case FocusCause::SwitchHard: return FocusOrigin::UserChoice;
            case FocusCause::UnmapTiling:
            case FocusCause::UnmapFloating:
            case FocusCause::UnmapGrouped: return FocusOrigin::AfterClose;
            case FocusCause::PointerFollow:
            case FocusCause::ToggleSpecialWorkspace: return FocusOrigin::Restore;
            case FocusCause::WorkspaceChange: return wasLastFocused ? FocusOrigin::Restore : FocusOrigin::UserChoice;
            case FocusCause::Unknown:
            case FocusCause::Other:
            case FocusCause::GroupCurrentChange:
            case FocusCause::NewWindow:
            case FocusCause::Ghosts: return FocusOrigin::Automatic;
        }
        return FocusOrigin::Automatic;
    }

    PressRecord recordPress(const PressContext& context) {
        if (!context.exclusive)
            return PressRecord{.scope = PressScope::ThisPress, .target = 0};
        if (context.onExclusive || context.under == 0)
            return PressRecord{};
        return PressRecord{.scope = PressScope::UntilFocus, .target = context.under};
    }

    bool clickFromPress(const PressRecord& press, WindowId window) {
        switch (press.scope) {
            case PressScope::None: return false;
            case PressScope::ThisPress: return true;
            case PressScope::UntilFocus: return press.target != 0 && press.target == window;
        }
        return false;
    }

} // namespace gf::deferredfocus
