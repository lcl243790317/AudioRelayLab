import UIKit
import XCTest
@testable import AudioRelayLab

final class KeyboardScopeTests:XCTestCase {
    @MainActor func testOrdinaryDisappearDoesNotEndAttachedEditorButDoneDoes() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return XCTFail("Native focus test requires the application's real scene")
        }
        let previous = scene.windows.first(where:{ $0.isKeyWindow })
        let window = UIWindow(windowScene:scene),owner = UIViewController()
        window.rootViewController = owner; window.makeKeyAndVisible(); owner.loadViewIfNeeded()
        let marker = UIView(frame:owner.view.bounds),field = UITextField(frame:CGRect(x:20,y:40,width:200,height:44))
        owner.view.addSubview(marker); owner.view.addSubview(field)
        let scope = KeyboardContentScope(); var cleared = 0
        scope.clearFocus = { cleared += 1 }; scope.attach(marker); scope.trackEditor(field)
        defer { scope.detach(); window.isHidden = true; previous?.makeKey() }
        XCTAssertTrue(field.becomeFirstResponder(),"Initial fixture focus must be real UIKit focus")
        XCTAssertTrue(KeyboardContentScope.firstResponder(in:owner.view) === field)
        scope.pageDisappeared()
        XCTAssertTrue(field.isFirstResponder,"Ordinary SwiftUI disappearance cannot interrupt an attached editor")
        XCTAssertEqual(cleared,0)
        scope.dismiss(source:"done")
        XCTAssertFalse(field.isFirstResponder); XCTAssertEqual(cleared,1)
        let next = UITextField(frame:CGRect(x:20,y:100,width:200,height:44)); owner.view.addSubview(next)
        XCTAssertTrue(next.becomeFirstResponder())
        scope.dismiss(source:"page-exit")
        XCTAssertTrue(next.isFirstResponder,"An old scope cannot resign the editor another page acquired")
        XCTAssertEqual(cleared,1)
    }
    @MainActor func testContentBoundaryExcludesKeyboardSiblingWithoutDependingOnKeyboardLayoutGuide() {
        let window = UIWindow(frame:CGRect(x:0,y:0,width:390,height:844))
        let owner = UIViewController(); window.rootViewController = owner
        owner.loadViewIfNeeded()
        // A hidden disposable UIWindow does not automatically install its root view.
        // Build the real content/sibling hierarchy without stealing the app key window.
        owner.view.frame = window.bounds; window.addSubview(owner.view)
        let marker = UIView(frame:owner.view.bounds); owner.view.addSubview(marker)
        let keyboard = UIView(frame:CGRect(x:0,y:500,width:390,height:344)); window.addSubview(keyboard)
        XCTAssertTrue(KeyboardContentScope.owner(of:marker) === owner)
        XCTAssertTrue(marker.window === window)
        XCTAssertFalse(keyboard.isDescendant(of:owner.view))
        let scope = KeyboardContentScope(); scope.attach(marker)
        XCTAssertNil(window.gestureRecognizers?.first { $0.delegate === scope })
        XCTAssertNotNil(owner.view.gestureRecognizers?.first { $0.delegate === scope })
        scope.detach()
        XCTAssertNil(owner.view.gestureRecognizers?.first { $0.delegate === scope })
    }
    @MainActor func testMultilineFieldInsideControlWrapperIsAnEditorBeforeChrome() {
        let root = UIView(frame:CGRect(x:0,y:0,width:390,height:500))
        let wrapper = UIControl(frame:CGRect(x:20,y:30,width:300,height:80))
        let field = UITextField(frame:wrapper.bounds)
        wrapper.addSubview(field); root.addSubview(wrapper)
        XCTAssertTrue(KeyboardContentScope.editor(at:CGPoint(x:60,y:50),in:root) === field)
        XCTAssertNil(KeyboardContentScope.editor(at:CGPoint(x:10,y:10),in:root))
        wrapper.isHidden = true
        XCTAssertNil(KeyboardContentScope.editor(at:CGPoint(x:60,y:50),in:root))
    }
    @MainActor func testClippedOffscreenEditorDoesNotBlockOutsideActions() {
        let root = UIView(frame:CGRect(x:0,y:0,width:390,height:500))
        let scroll = UIScrollView(frame:CGRect(x:0,y:0,width:390,height:200))
        scroll.clipsToBounds = true; root.addSubview(scroll)
        let editor = UITextView(frame:CGRect(x:0,y:180,width:390,height:300)); scroll.addSubview(editor)
        XCTAssertTrue(KeyboardContentScope.editor(at:CGPoint(x:30,y:190),in:root) === editor)
        XCTAssertNil(KeyboardContentScope.editor(at:CGPoint(x:30,y:250),in:root))
    }
}
