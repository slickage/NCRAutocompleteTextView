//
//  NCAutocompleteTextView.m
//  Example
//
//  Created by Daniel Weber on 9/28/14.
//  Copyright (c) 2014 Null Creature. All rights reserved.
//

#import "NCRAutocompleteTextView.h"
#import "SSAutocompleteMatch.h"

#define MAX_RESULTS 10

#define HIGHLIGHT_STROKE_COLOR [NSColor selectedMenuItemColor]
#define HIGHLIGHT_FILL_COLOR [NSColor selectedMenuItemColor]
#define HIGHLIGHT_RADIUS 0.0
#define INTERCELL_SPACING NSMakeSize(20.0, 3.0)

//#define WORD_BOUNDARY_CHARS [[NSCharacterSet alphanumericCharacterSet] invertedSet]

#define POPOVER_WIDTH 250.0
#define POPOVER_PADDING 0.0

//#define POPOVER_APPEARANCE NSAppearanceNameVibrantDark
#define POPOVER_APPEARANCE NSAppearanceNameVibrantLight

#define POPOVER_FONT [NSFont fontWithName:@"Helvetica Neue" size:13.0]
// The font for the characters that have already been typed
#define POPOVER_BOLDFONT [NSFont fontWithName:@"Helvetica Neue Medium" size:13.0]
#define POPOVER_TEXTCOLOR [NSColor blackColor]

#pragma mark -

@interface NCRAutocompleteTableRowView : NSTableRowView
@end
@implementation NCRAutocompleteTableRowView
- (void)drawSelectionInRect:(NSRect)dirtyRect {
  if (self.selectionHighlightStyle != NSTableViewSelectionHighlightStyleNone) {
    NSRect selectionRect = NSInsetRect(self.bounds, 0.5, 0.5);
    [HIGHLIGHT_STROKE_COLOR setStroke];
    [HIGHLIGHT_FILL_COLOR setFill];
    NSBezierPath *selectionPath = [NSBezierPath bezierPathWithRoundedRect:selectionRect xRadius:HIGHLIGHT_RADIUS yRadius:HIGHLIGHT_RADIUS];
    [selectionPath fill];
    [selectionPath stroke];
  }
}

- (NSBackgroundStyle)interiorBackgroundStyle {
  if (self.isSelected) {
    return NSBackgroundStyleDark;
  } else {
    return NSBackgroundStyleLight;
  }
}
@end

#pragma mark -

@interface NCRAutocompleteTextView ()
@property (nonatomic, weak) NSTableView *autocompleteTableView;
@property (nonatomic, strong) NSArray *matches;
// Used to highlight typed characters and insert text
@property (nonatomic, copy) NSString *substring;
// Used to keep track of when the insert cursor has moved so we
// can close the popover. See didChangeSelection:
@property (nonatomic, assign) NSInteger lastPos;
@property NSCharacterSet *wordBoundaryChars;
@property NSRange substringRange;
@end

@implementation NCRAutocompleteTextView

- (void)awakeFromNib {
  // Make a table view with 1 column and enclosing scroll view. It doesn't
  // matter what the frames are here because they are set when the popover
  // is displayed
  NSTableColumn *column1 = [[NSTableColumn alloc] initWithIdentifier:@"text"];
  [column1 setEditable:NO];
  [column1 setWidth:POPOVER_WIDTH - 2 * POPOVER_PADDING];

  // Setup word boundary chars and allow "@" and "#"
  NSMutableCharacterSet *allowedSet = [NSMutableCharacterSet characterSetWithCharactersInString:@"@#"];
  [allowedSet formUnionWithCharacterSet:[NSCharacterSet alphanumericCharacterSet]];
  _wordBoundaryChars = [allowedSet invertedSet];

  NSTableView *tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
  [tableView setSelectionHighlightStyle:NSTableViewSelectionHighlightStyleRegular];
  [tableView setBackgroundColor:[NSColor clearColor]];
  [tableView setRowSizeStyle:NSTableViewRowSizeStyleSmall];
  [tableView setIntercellSpacing:INTERCELL_SPACING];
  [tableView setHeaderView:nil];
  [tableView setRefusesFirstResponder:YES];
  [tableView setTarget:self];
  [tableView setDoubleAction:@selector(insert:)];
  [tableView addTableColumn:column1];
  [tableView setDelegate:self];
  [tableView setDataSource:self];
  self.autocompleteTableView = tableView;

  NSScrollView *tableScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  [tableScrollView setDrawsBackground:NO];
  [tableScrollView setDocumentView:tableView];
  [tableScrollView setHasVerticalScroller:YES];

  NSView *contentView = [[NSView alloc] initWithFrame:NSZeroRect];
  [contentView addSubview:tableScrollView];

  NSViewController *contentViewController = [[NSViewController alloc] init];
  [contentViewController setView:contentView];

  self.autocompletePopover = [[NSPopover alloc] init];
  self.autocompletePopover.appearance = [NSAppearance appearanceNamed:POPOVER_APPEARANCE];
  self.autocompletePopover.animates = NO;
  self.autocompletePopover.contentViewController = contentViewController;

  self.matches = [NSMutableArray array];
  self.lastPos = -1;

  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didChangeSelection:) name:@"NSTextViewDidChangeSelectionNotification" object:nil];
}

- (BOOL)caretAtEndOfWord {
  NSInteger caretPosition = [[[self selectedRanges] objectAtIndex:0] rangeValue].location;
  NSRange nextCharRange = NSMakeRange(caretPosition, 1);
  if (self.string.length >= nextCharRange.location + nextCharRange.length) {
    NSString *charAfterCaret = [self.string substringWithRange:nextCharRange];
    return [charAfterCaret isEqualToString:@" "];
  }
  else return YES;
}

- (void)keyDown:(NSEvent *)theEvent {
  NSInteger row = self.autocompleteTableView.selectedRow;
  BOOL shouldComplete = YES;
  switch (theEvent.keyCode) {
    case 51: //delete
      // Only show popup if deleting from the end of a word
      if ([self caretAtEndOfWord]) break;
    case 123: // left arrow
    case 124: // right arrow
      [self.autocompletePopover close];
      shouldComplete = NO;
      break;
    case 53:
      // Esc
      if (self.autocompletePopover.isShown)
        [self.autocompletePopover close];
      return; // Skip default behavior
    case 125:
      // Down
      if (self.autocompletePopover.isShown) {
        NSInteger nextRow = row + 1;
        // Skip over anything thats not a SSAutocompleteMatch object
        if (nextRow < self.matches.count && ![self.matches[nextRow] isKindOfClass:[SSAutocompleteMatch class]]) { nextRow += 1; }
        [self.autocompleteTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:nextRow] byExtendingSelection:NO];
        [self.autocompleteTableView scrollRowToVisible:self.autocompleteTableView.selectedRow];
        return; // Skip default behavior
      }
      break;
    case 126:
      // Up
      if (self.autocompletePopover.isShown) {
        NSInteger prevRow = row - 1;
        // Skip over anything thats not a SSAutocompleteMatch object
        if (prevRow >= 0 && ![self.matches[prevRow] isKindOfClass:[SSAutocompleteMatch class]]) { prevRow -= 1; }
        [self.autocompleteTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:prevRow] byExtendingSelection:NO];
        [self.autocompleteTableView scrollRowToVisible:self.autocompleteTableView.selectedRow];
        return; // Skip default behavior
      }
      break;
    case 36:
    case 48:
      // Return or tab
      if (self.autocompletePopover.isShown) {
        [self insert:self];
        return; // Skip default behavior
      }
    case 49:
      // Space
      if (self.autocompletePopover.isShown) {
        [self.autocompletePopover close];
      }
      break;
  }
  [super keyDown:theEvent];
  // If the caret isnt at the end of the word don't show the auto complete
  if (shouldComplete && [self caretAtEndOfWord]) {
    [self complete:self];
  }
}

- (void)insert:(id)sender {
  id obj = [self.matches objectAtIndex:self.autocompleteTableView.selectedRow];
  if (self.autocompleteTableView.selectedRow >= 0 && self.autocompleteTableView.selectedRow < self.matches.count && [obj isKindOfClass:[SSAutocompleteMatch class]]) {
    SSAutocompleteMatch *match = obj;
    NSInteger beginningOfWord = self.selectedRange.location - self.substring.length;
    NSRange range = NSMakeRange(beginningOfWord, self.substring.length);
    if ([self shouldChangeTextInRange:range replacementString:match.resultString]) {
      [self replaceCharactersInRange:range withString:match.resultString];
      [self didChangeText];
    }
  }
  [self.autocompletePopover close];
}

- (BOOL)resignFirstResponder {
  BOOL status = [super resignFirstResponder];
  if (status) {
    // Close popup when control loses focus
    [self.autocompletePopover close];
  }
  return status;
}

- (void)didChangeSelection:(NSNotification *)notification {
  if (labs(self.selectedRange.location - self.lastPos) > 1) {
    // If selection moves by more than just one character, hide autocomplete
    [self.autocompletePopover close];
  }
}

- (void)showAutocomplete {
  NSInteger index = 0;
  self.matches = [self completionsForPartialWordRange:self.substringRange indexOfSelectedItem:&index];

  if (self.matches.count > 0) {
    self.lastPos = self.selectedRange.location;
    [self.autocompleteTableView reloadData];

    [self.autocompleteTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
    [self.autocompleteTableView scrollRowToVisible:index];

    // Make the frame for the popover. We want it to shrink with a small number
    // of items to autocomplete but never grow above a certain limit when there
    // are a lot of items. The limit is set by MAX_RESULTS.
    NSInteger numberOfRows = MIN(self.autocompleteTableView.numberOfRows, MAX_RESULTS);
    CGFloat height = (self.autocompleteTableView.rowHeight + self.autocompleteTableView.intercellSpacing.height) * numberOfRows + 2 * POPOVER_PADDING;
    NSRect frame = NSMakeRect(0, 0, POPOVER_WIDTH, height);
    [self.autocompleteTableView.enclosingScrollView setFrame:NSInsetRect(frame, POPOVER_PADDING, POPOVER_PADDING)];
    [self.autocompletePopover setContentSize:NSMakeSize(NSWidth(frame), NSHeight(frame))];

    // We want to find the middle of the first character to show the popover.
    // firstRectForCharacterRange: will give us the rect at the begeinning of
    // the word, and then we need to find the half-width of the first character
    // to add to it.
    NSRect rect = [self firstRectForCharacterRange:self.substringRange actualRange:NULL];
    rect = [self.window convertRectFromScreen:rect];
    rect = [self convertRect:rect fromView:nil];
    NSString *firstChar = [self.substring substringToIndex:1];
    NSSize firstCharSize = [firstChar sizeWithAttributes:@{NSFontAttributeName:self.font}];
    rect.size.width = firstCharSize.width;

    [self.autocompletePopover showRelativeToRect:rect ofView:self preferredEdge:NSMaxYEdge];
  } else {
    [self.autocompletePopover close];
  }
}

- (void)complete:(id)sender {
  NSInteger startOfWord = self.selectedRange.location;
  for (NSInteger i = startOfWord - 1; i >= 0; i--) {
    if ([_wordBoundaryChars characterIsMember:[self.string characterAtIndex:i]]) {
      break;
    } else {
      startOfWord--;
    }
  }

  NSInteger lengthOfWord = 0;
  for (NSInteger i = startOfWord; i < self.string.length; i++) {
    if ([_wordBoundaryChars characterIsMember:[self.string characterAtIndex:i]]) {
      break;
    } else {
      lengthOfWord++;
    }
  }

  self.substring = [self.string substringWithRange:NSMakeRange(startOfWord, lengthOfWord)];
  self.substringRange = NSMakeRange(startOfWord, self.selectedRange.location - startOfWord);

  if (self.substringRange.length == 0 || lengthOfWord == 0) {
    // This happens when we just started a new word or if we have already typed the entire word
    [self.autocompletePopover close];
    return;
  }

  NSString *firstChar = [self.substring substringToIndex:1];
  // If the trigger word for the autocomplete doesnt start with an "@" or "#" symbol
  // make the user pause typing for at least 0.5s before showing the autocomplete
  // dialog. Also do not trigger it unless the user has typed at least 2 letters
  if ([firstChar isNotEqualTo:@"@"] && [firstChar isNotEqualTo:@"#"] && !self.autocompletePopover.isShown) {
    if (self.substring.length < 2) return;
    SEL showAutocomplete = @selector(showAutocomplete);
    // Cancel the previous validation selector
    [self.class cancelPreviousPerformRequestsWithTarget:self selector:showAutocomplete object:nil];

    // Show After 0.5 delay if not canceled
    [self performSelector:showAutocomplete withObject:nil afterDelay:0.5];
  }
  else {
    [self showAutocomplete];
  }
}

- (NSArray *)completionsForPartialWordRange:(NSRange)charRange indexOfSelectedItem:(NSInteger *)index {
  if ([self.delegate respondsToSelector:@selector(textView:completions:forPartialWordRange:indexOfSelectedItem:)]) {
    return [self.delegate textView:self completions:@[] forPartialWordRange:charRange indexOfSelectedItem:index];
  }
  return @[];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
  return self.matches.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
  NSTableCellView *cellView;

  // Add row for match
  if ([self.matches[row] isKindOfClass:[SSAutocompleteMatch class]]) {
    SSAutocompleteMatch *match = self.matches[row];
    NSImage *rowImage;

    // Retrieve row image if available
    if (match.icon) {
      rowImage = match.icon;
    }
    else if ([self.delegate respondsToSelector:@selector(textView:imageForCompletion:)]) {
      rowImage = [self.delegate textView:self imageForCompletion:match.displayString];
    }

    // If row has image use icon cell, if not use plain cell
    NSString *cellIdentifier = rowImage ? @"IconCellView" : @"PlainCellView";
    cellView = [tableView makeViewWithIdentifier:cellIdentifier owner:self];

    // Create cell if it doesn't exist
    if (cellView == nil) {
      cellView = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
      NSTextField *textField = [[NSTextField alloc] initWithFrame:NSZeroRect];
      [textField setBezeled:NO];
      [textField setDrawsBackground:NO];
      [textField setEditable:NO];
      [textField setSelectable:NO];
      [cellView addSubview:textField];
      cellView.textField = textField;

      // Add ImageView if row has icon
      if (rowImage) {
        NSImageView *imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        [imageView setImageFrameStyle:NSImageFrameNone];
        [imageView setImageScaling:NSImageScaleProportionallyDown];
        [cellView addSubview:imageView];
        cellView.imageView = imageView;
      }
      cellView.identifier = cellIdentifier;
    }

    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:match.displayString attributes:@{NSFontAttributeName:POPOVER_FONT, NSForegroundColorAttributeName:POPOVER_TEXTCOLOR}];

    [cellView.textField setAttributedStringValue:as];
    [cellView.imageView setImage:rowImage];
  }
  else { // Anything that isn't a match is a separator
    cellView = [tableView makeViewWithIdentifier:@"Separator" owner:self];
    if (cellView == nil) {
      cellView = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
      NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(0, 10, POPOVER_WIDTH-(INTERCELL_SPACING.width), 1)];
      [separator setBoxType:NSBoxSeparator];
      [cellView addSubview:separator];
      cellView.identifier = @"Separator";
    }
  }
  return cellView;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
  // Matches are selectable
  if ([self.matches[row] isKindOfClass:[SSAutocompleteMatch class]]) {
    return YES;
  }
  // Separators are not selectable
  else return NO;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
  return [[NCRAutocompleteTableRowView alloc] init];
}

@end
