#include <zlib.h>
#include <libkern/OSCacheControl.h>
#include <stdlib.h>
#include <xlocale.h>

// Export Apple's compound locale mask as an integer constant for Swift.
enum { ZeeSwiftCLocaleMask = LC_ALL_MASK };
