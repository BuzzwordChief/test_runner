#import <Foundation/Foundation.h>

void run(const char *program_path, const char **args, uint32_t arg_count, const char *standard_output_path, const char *standard_error_path) {
    @autoreleasepool {
        NSString *output     = [NSString stringWithCString:standard_output_path encoding:NSUTF8StringEncoding];
        NSString *output_err = [NSString stringWithCString:standard_error_path  encoding:NSUTF8StringEncoding];
        
        NSMutableArray *ns_arg_array = [NSMutableArray array];
        for (uint32_t i = 0; i < arg_count; i++) {
            [ns_arg_array addObject:[NSString stringWithCString:args[i] encoding:NSUTF8StringEncoding]];
        }
        
        [[NSFileManager defaultManager] createFileAtPath:output     contents:nil attributes:nil];
        [[NSFileManager defaultManager] createFileAtPath:output_err contents:nil attributes:nil];
        
        NSTask *task = [[NSTask alloc]init];
        
        task.executableURL  = [NSURL fileURLWithPath:[NSString stringWithCString:program_path encoding:NSUTF8StringEncoding]];
        task.arguments      = ns_arg_array;
        task.standardOutput = [NSFileHandle fileHandleForWritingToURL:[NSURL fileURLWithPath:output]     error:NULL];
        task.standardError  = [NSFileHandle fileHandleForWritingToURL:[NSURL fileURLWithPath:output_err] error:NULL];
        
        [task launch];
        NSLog(@"IsRunning: %hhd", [task isRunning]);
        [task waitUntilExit];
        NSLog(@"IsRunning: %hhd", [task isRunning]);
    }
}

int main(int argc, const char * argv[]) {
    run("/Users/bc/source/test_runner/test/example_program", argv, argc, "/Users/bc/source/testing_ground/output.txt", "/Users/bc/source/testing_ground/output_err.txt");
    
    return 0;
}

