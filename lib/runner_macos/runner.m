#import <Foundation/Foundation.h>
#import <stdio.h>

int run(const char *program_path, const char **args, uint32_t arg_count, int stdout_fh, int stderr_fh) {
    @autoreleasepool {
        NSMutableArray *ns_arg_array = [NSMutableArray array];
        for (uint32_t i = 0; i < arg_count; i++) {
            [ns_arg_array addObject:[NSString stringWithCString:args[i] encoding:NSUTF8StringEncoding]];
        }

        NSTask *task = [[NSTask alloc] init];
        task.executableURL  = [NSURL fileURLWithPath:[NSString stringWithCString:program_path encoding:NSUTF8StringEncoding]];
        task.arguments      = ns_arg_array;
        task.standardOutput = [[NSFileHandle alloc] initWithFileDescriptor:stdout_fh];
        task.standardError  = [[NSFileHandle alloc] initWithFileDescriptor:stderr_fh];

        [task launch];
        [task waitUntilExit];
        return [task terminationStatus];
    }
}
