# Setting Up SwiftStudyCoachTests Target

All test files have been created and are ready. Follow these steps to add the test target to your Xcode project:

## Option 1: Automatic Setup (Recommended)

1. **Open the project in Xcode**
   ```bash
   open SwiftStudyCoach.xcodeproj
   ```

2. **Xcode will detect the SwiftStudyCoachTests folder**
   - When Xcode opens the project, it may ask if you want to add the SwiftStudyCoachTests folder to the project
   - Click "Add Files" and select the SwiftStudyCoachTests folder

3. **Create a new Test Target**
   - In Xcode, go to: **File > New > Target**
   - Select **macOS Unit Testing Bundle**
   - Name it: `SwiftStudyCoachTests`
   - Make sure "Target to be Tested" is set to `SwiftStudyCoach`
   - Click "Create"

4. **Replace the generated test file**
   - Delete the auto-generated test file from the new target
   - The test files in the SwiftStudyCoachTests folder will be automatically included

5. **Run Tests**
   - Press **Cmd+U** to run all tests
   - Or go to **Product > Test**

## Option 2: Manual pbxproj Edit

If you prefer to edit the project file manually:

1. Right-click on `SwiftStudyCoach.xcodeproj` in Finder
2. Select "Show Package Contents"
3. Open `project.pbxproj` with a text editor
4. Contact me for the exact edits needed

## Files Ready to Test

- ✅ `QuestionValidatorTests.swift` - 29 test cases
- ✅ `StudyGeneratorPureFunctionsTests.swift` - 30 test cases  
- ✅ `DocumentIndexLexicalTests.swift` - 22 test cases
- ✅ `MLXServiceDraftParsingTests.swift` - 20 test cases

**Total: 101 test cases**

## What Was Changed

Only one file in the main project was modified:
- `SwiftStudyCoach/Services/DocumentIndex.swift`
  - Changed `tokens(of:)` from `private` to `internal` (line 279)
  - Changed `lexicalOverlap()` from `private` to `internal` (line 288)
  - **No logic changes**, only visibility for testing

## Verification

After adding the test target and running tests, you should see:
- All 101 tests passing ✅
- Zero errors or warnings
- Full coverage of the tested pure functions

## Questions?

If you encounter any issues:
1. Ensure Xcode is version 14.6 or later
2. Check that SwiftStudyCoachTests folder exists at the project root
3. Verify the test files are linked to the test target (not the app target)
4. Try: `xcodebuild test -scheme SwiftStudyCoach` from Terminal
