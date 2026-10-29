// removefile(3) for Swift with any SDK: the macOS 27 SDK exposes it through Darwin, the macOS 26 SDK (Xcode 26, our
// CI runners) has the header but no Swift module for it.
#include <removefile.h>
