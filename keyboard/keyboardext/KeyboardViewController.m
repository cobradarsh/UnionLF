#import "KeyboardViewController.h"

// PHASE 1: prove the keyboard loads, is selectable, and can type into the host app.
// The reply buttons are sample text for now; Phase 2 fills them from the replies the
// Wingman Plus tweak generates (read over a shared channel).
@interface KeyboardViewController ()
@end

@implementation KeyboardViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.14 alpha:1];

    // Keyboards must declare their own height.
    NSLayoutConstraint *h = [self.view.heightAnchor constraintEqualToConstant:268];
    h.priority = UILayoutPriorityRequired - 1;
    h.active = YES;

    UILabel *title = [UILabel new];
    title.text = @"WINGMAN";
    title.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    title.textColor = [UIColor colorWithRed:0.95 green:0.26 blue:0.45 alpha:1];

    UIButton *b1 = [self replyButton:@"Hey — your smile in that third photo is genuinely unfair 😏"];
    UIButton *b2 = [self replyButton:@"Okay, we clearly have to settle the pineapple-on-pizza debate in person."];

    UIStackView *replies = [[UIStackView alloc] initWithArrangedSubviews:@[b1, b2]];
    replies.axis = UILayoutConstraintAxisVertical;
    replies.spacing = 8;
    replies.distribution = UIStackViewDistributionFillEqually;

    UIButton *globe = [self chromeButton:@"🌐  Keyboards"];
    [globe addTarget:self action:@selector(nextKeyboard) forControlEvents:UIControlEventTouchUpInside];
    UIButton *del = [self chromeButton:@"⌫"];
    [del addTarget:self action:@selector(backspace) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[globe, del]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8;
    [del.widthAnchor constraintEqualToConstant:64].active = YES; // fixed-width backspace

    UIStackView *root = [[UIStackView alloc] initWithArrangedSubviews:@[title, replies, row]];
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 10;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [root.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [root.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
        [root.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-8],
    ]];
}

- (UIButton *)replyButton:(NSString *)t {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15];
    b.titleLabel.numberOfLines = 0;
    b.titleLabel.textAlignment = NSTextAlignmentLeft;
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 12);
    b.backgroundColor = [UIColor colorWithRed:0.18 green:0.18 blue:0.21 alpha:1];
    b.layer.cornerRadius = 10;
    [b addTarget:self action:@selector(insertFrom:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIButton *)chromeButton:(NSString *)t {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:[UIColor colorWithWhite:0.9 alpha:1] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    b.backgroundColor = [UIColor colorWithRed:0.22 green:0.22 blue:0.25 alpha:1];
    b.layer.cornerRadius = 10;
    return b;
}

- (void)insertFrom:(UIButton *)b {
    NSString *t = b.currentTitle;
    if (t.length) [self.textDocumentProxy insertText:t];
}
- (void)nextKeyboard { [self advanceToNextInputViewController]; }
- (void)backspace { [self.textDocumentProxy deleteBackward]; }

@end
