#import <Foundation/Foundation.h>
#include "include/capi/cef_app_capi.h"
#include "include/cef_api_hash.h"
#include <dlfcn.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *executable = [NSString stringWithUTF8String:argv[0]];
        NSString *frameworks = [[[[executable stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        NSString *framework = [frameworks stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
        void *sandboxLibrary = dlopen([[framework stringByAppendingPathComponent:@"Libraries/libcef_sandbox.dylib"] fileSystemRepresentation], RTLD_NOW | RTLD_LOCAL);
        if (!sandboxLibrary) return 1;
        auto initializeSandbox = reinterpret_cast<void *(*)(int, char **)>(dlsym(sandboxLibrary, "cef_sandbox_initialize"));
        auto destroySandbox = reinterpret_cast<void (*)(void *)>(dlsym(sandboxLibrary, "cef_sandbox_destroy"));
        if (!initializeSandbox || !destroySandbox) return 1;
        void *sandbox = initializeSandbox(argc, argv);
        if (!sandbox) return 1;
        void *library = dlopen([[framework stringByAppendingPathComponent:@"Chromium Embedded Framework"] fileSystemRepresentation], RTLD_NOW | RTLD_LOCAL);
        if (!library) return 1;
        auto apiHash = reinterpret_cast<decltype(&cef_api_hash)>(dlsym(library, "cef_api_hash"));
        auto execute = reinterpret_cast<decltype(&cef_execute_process)>(dlsym(library, "cef_execute_process"));
        if (!apiHash || !execute) return 1;
        const char *actualHash = apiHash(CEF_API_VERSION, 0);
        if (!actualHash || strcmp(actualHash, CEF_API_HASH_PLATFORM)) return 1;
        cef_main_args_t args{argc, argv};
        int result = execute(&args, nullptr, nullptr);
        destroySandbox(sandbox);
        return result;
    }
}
