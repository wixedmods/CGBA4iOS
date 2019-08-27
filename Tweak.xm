#import <UIKit/UIKit.h>
#import "memptrs.h"

#if DEBUG
#define NSLog(args...) NSLog(@"[CGBA] "args)
#else
#define NSLog(args...)
#endif
#define min(a,b) ((a<b)?a:b)

#define GetVRAMSize(memptrs) 0x4000
#define GetVRAMDataPt(memptrs) (memptrs->rambankdata_ - GetVRAMSize(memptrs))
#define GetRAMDataPt(memptrs) memptrs->rambankdata_
#define GetRAMSize(memptrs) (memptrs->wramdata_[0] - GetRAMDataPt(memptrs))
#define GetROMDataPt(memptrs) (memptrs->memchunk_ + 0x4000)
#define GetROMSize(memptrs) (GetVRAMDataPt(memptrs) - GetROMDataPt(memptrs))

static NSSet *expectedTitlesSet;
static NSIndexPath *cellIndexPath;
static NSString *suffix;
static gambatte::MemPtrs *memptrs = NULL;
static BOOL RTCEnabled = NO;
static BOOL shouldEnableRTC = NO;
static unsigned char *GBAPointers[3];
typedef void(^RSTAlertViewSelectionHandler)(UIAlertView *alertView, NSInteger buttonIndex);

@interface RSTFileBrowserViewController : UITableViewController
- (NSString *)filepathForIndexPath:(NSIndexPath *)path;
- (void)refreshDirectory;
- (void)setIgnoreDirectoryContentChanges:(BOOL)ignoreDirectoryContentChanges;
@end

@interface GBAROMTableViewController : RSTFileBrowserViewController<UITableViewDelegate>
@end

static void __CGBA4iOS_corrupt(NSFileHandle *in, NSFileHandle *out, long len, long skip) {
	NSData *data;
	for (long i = 0; i < len; i+=skip) {
		unsigned char byte = (unsigned char)arc4random_uniform(255);
		data = [NSData dataWithBytes:&byte length:1];
		[out writeData:data];
		[in seekToFileOffset:out.offsetInFile];
		if (skip-1) {
			data = [in readDataOfLength:min(len-i,skip-1)];
			[out writeData:data];
		}
	}
	NSLog(@"Got to end");
}

static void __CGBA4iOS_RTC_tick(NSTimer *timer) {
	if (!memptrs && !GBAPointers[0]) return;
	long size = GetVRAMSize(memptrs);
	if (!size) return;
	NSPointerArray *ptArray = [NSPointerArray pointerArrayWithOptions:(NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality)];
#define _add(pt) [ptArray addPointer:(void *)pt]
#define add(pt, size, count) {_add(pt); _add(size); _add(count);}
	if (memptrs) {
		// I'm not sure if I should be corrupting the ROM but the corruptions are better this way so I'll keep it
		add(GetROMDataPt(memptrs), GetROMSize(memptrs), 3);
		add(GetVRAMDataPt(memptrs), GetVRAMSize(memptrs), 5);
		add(GetRAMDataPt(memptrs), GetRAMSize(memptrs), 3);
	}
	if (GBAPointers[0]) {
		add(GBAPointers[0], 0x40000, 10);
		add(GBAPointers[1], 0x20000, 10);
		add(GBAPointers[2], 0x400, 5);
	}
#undef add
#undef _add
	for (unsigned char ptIndex = 0; ptIndex < ptArray.count; ptIndex+=3) {
		unsigned char *data = (unsigned char *)[ptArray pointerAtIndex:ptIndex];
		long size = (long)[ptArray pointerAtIndex:ptIndex+1];
		long count = (long)[ptArray pointerAtIndex:ptIndex+2];
		if (!data || !size) continue;
		for (long i = 0; i < count; i++) {
			data[arc4random_uniform(size - 1)] = (unsigned char)arc4random_uniform(255);
		}
	}
}

%hook GBAROMTableViewController

- (void)didDetectLongPressGesture:(UILongPressGestureRecognizer *)gestureRecognizer {
	cellIndexPath = [self.tableView indexPathForCell:(id)[gestureRecognizer view]];
	%orig;
	cellIndexPath = nil;
}

- (void)presentViewController:(UIAlertController *)vc animated:(BOOL)animated completion:(void(^)(void))completion {
	if ([vc isKindOfClass:[UIAlertController class]]) {
		NSMutableSet *inputSet = [NSMutableSet setWithArray:[vc.actions valueForKeyPath:@"title"]];
		[inputSet intersectSet:expectedTitlesSet];
		if (inputSet.count == expectedTitlesSet.count) {
			NSIndexPath *indexPath = cellIndexPath;
			NSString *filepath = [self filepathForIndexPath:indexPath];
			if (![[filepath.pathExtension lowercaseString] isEqualToString:@"zip"]) {
				if (![[filepath stringByDeletingPathExtension] hasSuffix:suffix]) {
					[vc addAction:[UIAlertAction
						actionWithTitle:@"Duplicate & Corrupt"
						style:UIAlertActionStyleDefault
						handler:^(id action){
							self.ignoreDirectoryContentChanges = YES;
							FILE *in_c = fopen(filepath.UTF8String, "r");
							if (!in_c) return;
							NSFileHandle *in = [[NSFileHandle alloc] initWithFileDescriptor:fileno(in_c) closeOnDealloc:YES];
							if (!in) {
								fclose(in_c);
								return;
							}
							NSString *outPath = [NSString stringWithFormat:@"%@/Corrupted %@%@.%@", filepath.stringByDeletingLastPathComponent, filepath.lastPathComponent.stringByDeletingPathExtension, suffix, filepath.pathExtension];
							NSLog(@"Out: %@", outPath);
							NSString *tmpPath = [outPath stringByAppendingPathExtension:@"tmp"];
							[NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
							[NSFileManager.defaultManager copyItemAtPath:filepath toPath:tmpPath error:nil];
							char *tmpPath_c = (char *)malloc(strlen(tmpPath.UTF8String)+1);
							strcpy(tmpPath_c, tmpPath.UTF8String);
							FILE *out_c = fopen(tmpPath_c, "r+");
							free(tmpPath_c);
							if (!out_c) return;
							NSFileHandle *out = [[NSFileHandle alloc] initWithFileDescriptor:fileno(out_c) closeOnDealloc:YES];
							if (!out) {
								fclose(out_c);
								return;
							}
							//BOOL isGBAGame = [filepath.pathExtension.lowercaseString isEqualToString:@"gba"];
							int inset = arc4random_uniform(10000);
							[in seekToEndOfFile];
							long len = in.offsetInFile - inset - 100;
							if (len > 0) {
								[in seekToFileOffset:inset];
								[out seekToFileOffset:inset];
								__CGBA4iOS_corrupt(in, out, len, arc4random_uniform(1000)+100);
								NSLog(@"Corruption completed, supposedly");
							}
							[out closeFile];
							[in closeFile];
							[NSFileManager.defaultManager
								replaceItemAtURL:[NSURL fileURLWithPath:outPath]
								withItemAtURL:[NSURL fileURLWithPath:tmpPath]
								backupItemName:nil
								options:0
								resultingItemURL:nil
								error:nil
							];
							[NSFileManager.defaultManager
								removeItemAtPath:[outPath.stringByDeletingPathExtension stringByAppendingPathExtension:@"sav"]
								error:nil
							];
							self.ignoreDirectoryContentChanges = NO;
							NSLog(@"Directory should've been refreshed by now");
						}
					]];
				}
				[vc addAction:[UIAlertAction
					actionWithTitle:@"Corrupt in Real Time"
					style:UIAlertActionStyleDefault
					handler:^(id action){
						shouldEnableRTC = YES;
						[self tableView:self.tableView didSelectRowAtIndexPath:indexPath];
					}
				]];
			}
		}
	}
	%orig;
}

- (void)startROM:(id)rom showSameROMAlertIfNeeded:(BOOL)showSameROMAlertIfNeeded {
	RTCEnabled = shouldEnableRTC;
	shouldEnableRTC = NO;
	%orig;
}

%end

%hook RSTFileBrowserViewController

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = %orig;
	if (([self class] == %c(GBAROMTableViewController)) && ![cell.detailTextLabel.text hasPrefix:@"C"] && [cell.textLabel.text hasSuffix:suffix]) {
		cell.textLabel.text = [cell.textLabel.text substringToIndex:cell.textLabel.text.length-suffix.length];
		cell.detailTextLabel.text = [@"C" stringByAppendingString:cell.detailTextLabel.text];
	}
	return cell;
}

%end

%hook UIAlertView

// Not a standard UIAlertView method, this is an extension
- (void)showWithSelectionHandler:(RSTAlertViewSelectionHandler)selectionHandler {
	if ([self.title isEqualToString:NSLocalizedString(@"Rename Game", @"")] &&
		[[self buttonTitleAtIndex:self.cancelButtonIndex] isEqualToString:NSLocalizedString(@"Cancel", @"")] &&
		[[self buttonTitleAtIndex:self.firstOtherButtonIndex] isEqualToString:NSLocalizedString(@"Rename", @"")])
	{
		UITextField *textField = [self textFieldAtIndex:0];
		if ([textField.text hasSuffix:suffix]) {
			textField.text = [textField.text substringToIndex:textField.text.length-suffix.length];
			RSTAlertViewSelectionHandler modifiedHandler = ^(UIAlertView *alert, NSInteger buttonIndex){
				UITextField *_textField = [alert textFieldAtIndex:0];
				_textField.text = [_textField.text stringByAppendingString:suffix];
				selectionHandler(alert, buttonIndex);
			};
			%orig(modifiedHandler);
			return;
		}
	}
	%orig;
}

%end

#pragma mark - Hooks for GBC real time corruption

%hookf(void, "__ZN8gambatte7MemPtrs10setRambankEjj", gambatte::MemPtrs *self, unsigned ramFlags, unsigned rambank) {
	%orig;
	memptrs = self;
}

%hookf(bool, "__ZN8gambatte7MemPtrsD1Ev", gambatte::MemPtrs *self) {
	memptrs = NULL;
	return %orig;
}

%hookf(void, "__ZN9EmuSystem15closeSystem_GBCEv", unsigned char *self) {
	memptrs = NULL;
	%orig;
}

#pragma mark - Hooks for GBA real time corruption

%hookf(bool, "__Z18CPUReadBatteryFileR6GBASysPKc", unsigned char& gba, char const *filename) {
	bool result;
	GBAPointers[0] = NULL;
	if ((result = %orig)) {
		unsigned char *gbaPt = &gba;
		int diff = ((sizeof(void *) == 4) * 2064);
		GBAPointers[0] = gbaPt + 271624 - (diff ? (diff + 8) : 0); // Work RAM
		GBAPointers[1] = gbaPt + 88152 - diff; // Video RAM (2064 diff)
		GBAPointers[2] = gbaPt + 219224 - diff; // Palette RAM (2064 diff)
	}
	return result;
}

%hookf(void, "__ZN9EmuSystem15closeSystem_GBAEv", unsigned char *self) {
	GBAPointers[0] = NULL;
	%orig;
}

%ctor {
	expectedTitlesSet = [NSSet setWithArray:@[
		NSLocalizedString(@"Cancel", @""),
		NSLocalizedString(@"Rename Game", @""),
		NSLocalizedString(@"Share Game", @"")
	]];
	GBAPointers[0] = NULL;
	char buffer[5];
	for (unsigned char i=0; i<=3; i++) {
		buffer[i] = i+0x11;
	}
	buffer[4] = 0;
	suffix = @(buffer);
	// Up to 3 bytes are corrupted in each type of memory every second. Even this can be really powerful.
	[NSTimer scheduledTimerWithTimeInterval:1.0
		repeats:YES
		block:^(NSTimer *timer){
			if (RTCEnabled) __CGBA4iOS_RTC_tick(timer);
		}
	];
}