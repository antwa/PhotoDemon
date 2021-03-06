VERSION 5.00
Begin VB.UserControl buttonStrip 
   BackColor       =   &H00FFFFFF&
   ClientHeight    =   765
   ClientLeft      =   0
   ClientTop       =   0
   ClientWidth     =   2745
   BeginProperty Font 
      Name            =   "Tahoma"
      Size            =   8.25
      Charset         =   0
      Weight          =   400
      Underline       =   0   'False
      Italic          =   0   'False
      Strikethrough   =   0   'False
   EndProperty
   ScaleHeight     =   51
   ScaleMode       =   3  'Pixel
   ScaleWidth      =   183
   ToolboxBitmap   =   "buttonStrip.ctx":0000
End
Attribute VB_Name = "buttonStrip"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = True
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
'***************************************************************************
'PhotoDemon "Button Strip" control
'Copyright 2014-2015 by Tanner Helland
'Created: 13/September/14
'Last updated: 12/January/15
'Last update: rewrite control to handle its own caption and tooltip translations
'
'In a surprise to precisely no one, PhotoDemon has some unique needs when it comes to user controls - needs that
' the intrinsic VB controls can't handle.  These range from the obnoxious (lack of an "autosize" property for
' anything but labels) to the critical (no Unicode support).
'
'As such, I've created many of my own UCs for the program.  All are owner-drawn, with the goal of maintaining
' visual fidelity across the program, while also enabling key features like Unicode support.
'
'A few notes on this button strip control, specifically:
'
' 1) The control supports an arbitrary number of button captions.  Captions are auto-wrapped, but DrawText requires word breaks to do this,
'     so you can't rely on hyphenation for over-long words - plan accordingly!
' 2) High DPI settings are handled automatically.
' 3) A hand cursor is automatically applied, and clicks on individual buttons are returned via the Click event.
' 4) Coloration is automatically handled by PD's internal theming engine.
' 5) When the control receives focus via keyboard, a special focus rect is drawn.  Focus via mouse is conveyed via text glow.
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://photodemon.org/about/license/
'
'***************************************************************************

Option Explicit

'This control really only needs one event raised - Click
Public Event Click(ByVal buttonIndex As Long)

'These events are provided as a convenience, for hosts who may want to reroute mousewheel events to some other control.
' (In PD, the metadata browser does this.)
Public Event MouseWheelVertical(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long, ByVal scrollAmount As Double)

'Flicker-free window painter
Private WithEvents cPainter As pdWindowPainter
Attribute cPainter.VB_VarHelpID = -1

'Retrieve the width and height of a string
Private Declare Function GetTextExtentPoint32 Lib "gdi32" Alias "GetTextExtentPoint32W" (ByVal hDC As Long, ByVal lpStrPointer As Long, ByVal cbString As Long, ByRef lpSize As POINTAPI) As Long

'Retrieve specific metrics on a font (in our case, crucial for aligning button images against the font baseline and ascender)
Private Declare Function GetTextMetrics Lib "gdi32" Alias "GetTextMetricsA" (ByVal hDC As Long, ByRef lpMetrics As TEXTMETRIC) As Long
Private Type TEXTMETRIC
    tmHeight As Long
    tmAscent As Long
    tmDescent As Long
    tmInternalLeading As Long
    tmExternalLeading As Long
    tmAveCharWidth As Long
    tmMaxCharWidth As Long
    tmWeight As Long
    tmOverhang As Long
    tmDigitizedAspectX As Long
    tmDigitizedAspectY As Long
    tmFirstChar As Byte
    tmLastChar As Byte
    tmDefaultChar As Byte
    tmBreakChar As Byte
    tmItalic As Byte
    tmUnderlined As Byte
    tmStruckOut As Byte
    tmPitchAndFamily As Byte
    tmCharSet As Byte
End Type

'API technique for drawing a focus rectangle; used only for designer mode (see the Paint method for details)
Private Declare Function DrawFocusRect Lib "user32" (ByVal hDC As Long, lpRect As RECT) As Long

'Previously, we used VB's internal label control to render the text caption.  This is now handled dynamically,
' via a pdFont object.
Private curFont As pdFont

'If a given caption needs to be dynamically shrunk (because it's too long to fit, and DrawText can't hyphenate it for whatever reason),
' we fall back to a temporary font object.  This is preferable to overwriting the main font object, as font creation is expensive, and we
' can simply skip creating this font if text fits okay (as it does for en-US).
Private shrinkFont As pdFont

'Rather than use an StdFont container (which requires VB to create redundant font objects), we track font properties manually,
' via dedicated properties.
Private m_FontSize As Single
Private m_FontBold As Boolean

'Mouse and keyboard input handlers
Private WithEvents cMouseEvents As pdInputMouse
Attribute cMouseEvents.VB_VarHelpID = -1
Private WithEvents cKeyEvents As pdInputKeyboard
Attribute cKeyEvents.VB_VarHelpID = -1

'Current button indices
Private m_ButtonIndex As Long
Private m_ButtonHoverIndex As Long

'Array of current button entries
Private Type buttonEntry
    btCaptionEn As String           'Current button caption, in its original English
    btCaptionTranslated As String   'Current button caption, translated into the active language (if English is active, this is a copy of btCaptionEn)
    btBounds As RECT                'Boundaries of this button (full clickable area, inclusive - meaning 1px border NOT included)
    btCaptionRect As RECT           'Bounding rect of the caption.  This is dynamically calculated by the updateControlSize function
    btImage As pdDIB                'Optional image to use with the button.
    btImageDisabled As pdDIB        'Auto-created disabled version of the image
    btImageHover As pdDIB           'Auto-created hover (glow) version of the image
    btImageCoords As POINTAPI       '(x, y) position of the button image, if any
    btFontSize As Single            'If a button caption fits just fine, this value is 0.  If a translation is active and a button caption must be shrunk,
                                    ' this value will be non-zero, and the button renderer must use it when rendering the button.
End Type

Private m_Buttons() As buttonEntry
Private m_numOfButtons As Long

'Persistent back buffer, which we manage internally
Private m_BackBuffer As pdDIB

'If the mouse is currently INSIDE the control, this will be set to TRUE
Private m_MouseInsideUC As Boolean

'When the option button receives focus via keyboard (e.g. NOT by mouse events), we draw a focus rect to help orient the user.
Private m_FocusRectActive As Long

'Additional helper for rendering themed and multiline tooltips
Private toolTipManager As pdToolTip

'Padding between images (if any) and text.  This is automatically adjusted according to DPI, so set this value as it would be at the
' Windows default of 96 DPI
Private Const IMG_TEXT_PADDING As Long = 4

'The Enabled property is a bit unique; see http://msdn.microsoft.com/en-us/library/aa261357%28v=vs.60%29.aspx
Public Property Get Enabled() As Boolean
Attribute Enabled.VB_UserMemId = -514
    Enabled = UserControl.Enabled
End Property

Public Property Let Enabled(ByVal newValue As Boolean)
    
    UserControl.Enabled = newValue
    PropertyChanged "Enabled"
    
    'Redraw the control
    redrawBackBuffer
    
End Property

'Font settings are handled via dedicated properties, to avoid the need for an internal VB font object
Public Property Get FontBold() As Boolean
    FontBold = m_FontBold
End Property

Public Property Let FontBold(ByVal newBoldSetting As Boolean)
    If newBoldSetting <> m_FontBold Then
        m_FontBold = newBoldSetting
        refreshFont
    End If
End Property

Public Property Get FontSize() As Single
    FontSize = m_FontSize
End Property

Public Property Let FontSize(ByVal newSize As Single)
    If newSize <> m_FontSize Then
        m_FontSize = newSize
        refreshFont
    End If
End Property

'When the font used for the button changes in some way, it can be recreated (refreshed) using this function.  Note that font
' creation is expensive, so it's worthwhile to avoid this step as much as possible.
Private Sub refreshFont()
    
    Dim fontRefreshRequired As Boolean
    fontRefreshRequired = curFont.hasFontBeenCreated
    
    'Update each font parameter in turn.  If one (or more) requires a new font object, the font will be recreated as the final step.
    
    'Font face is always set automatically, to match the current program-wide font
    If (Len(g_InterfaceFont) <> 0) And (StrComp(curFont.getFontFace, g_InterfaceFont, vbBinaryCompare) <> 0) Then
        fontRefreshRequired = True
        curFont.setFontFace g_InterfaceFont
    End If
    
    'In the future, I may switch to GDI+ for font rendering, as it supports floating-point font sizes.  In the meantime, we check
    ' parity using an Int() conversion, as GDI only supports integer font sizes.
    If Int(m_FontSize) <> Int(curFont.getFontSize) Then
        fontRefreshRequired = True
        curFont.setFontSize m_FontSize
    End If
    
    'This control currently supports bold text, but not italics
    If m_FontBold <> curFont.getFontBold Then
        fontRefreshRequired = True
        curFont.setFontBold m_FontBold
    End If
        
    'Request a new font, if one or more settings have changed
    If fontRefreshRequired Then curFont.createFontObject
        
    'Also, each button needs to be rebuilt to reflect the new font metrics
    updateControlSize

End Sub

'A few key events are also handled
Private Sub cKeyEvents_KeyDownCustom(ByVal Shift As ShiftConstants, ByVal vkCode As Long, markEventHandled As Boolean)

    If (vkCode = VK_RIGHT) Then
        
        'See if a focus rect is already active
        If (m_FocusRectActive >= 0) Then
            m_FocusRectActive = m_FocusRectActive + 1
        Else
            m_FocusRectActive = m_ButtonIndex + 1
        End If
        
        'Bounds-check the new m_FocusRectActive index
        If m_FocusRectActive >= m_numOfButtons Then m_FocusRectActive = 0
        
        'Redraw the button strip
        redrawBackBuffer
        
    ElseIf (vkCode = VK_LEFT) Then
    
        'See if a focus rect is already active
        If (m_FocusRectActive >= 0) Then
            m_FocusRectActive = m_FocusRectActive - 1
        Else
            m_FocusRectActive = m_ButtonIndex - 1
        End If
        
        'Bounds-check the new m_FocusRectActive index
        If m_FocusRectActive < 0 Then m_FocusRectActive = m_numOfButtons - 1
        
        'Redraw the button strip
        redrawBackBuffer
        
    'If a focus rect is active, and space is pressed, activate the button with focus
    ElseIf (vkCode = VK_SPACE) Then

        If m_FocusRectActive >= 0 Then ListIndex = m_FocusRectActive
        
    End If

End Sub

Private Sub cMouseEvents_MouseWheelVertical(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long, ByVal scrollAmount As Double)
    RaiseEvent MouseWheelVertical(Button, Shift, x, y, scrollAmount)
End Sub

'The pdWindowPaint class raises this event when the control needs to be redrawn.  The passed coordinates contain the
' rect returned by GetUpdateRect (but with right/bottom measurements pre-converted to width/height).
Private Sub cPainter_PaintWindow(ByVal winLeft As Long, ByVal winTop As Long, ByVal winWidth As Long, ByVal winHeight As Long)

    'Flip the relevant chunk of the buffer to the screen
    BitBlt UserControl.hDC, winLeft, winTop, winWidth, winHeight, m_BackBuffer.getDIBDC, winLeft, winTop, vbSrcCopy
    
End Sub

'To improve responsiveness, MouseDown is used instead of Click
Private Sub cMouseEvents_MouseDownCustom(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long)

    Dim mouseClickIndex As Long
    mouseClickIndex = isMouseOverButton(x, y)
    
    'Disable any keyboard-generated focus rectangles
    m_FocusRectActive = -1
    
    If Me.Enabled And (mouseClickIndex >= 0) Then
        
        If m_ButtonIndex <> mouseClickIndex Then
            ListIndex = mouseClickIndex
        End If
        
    End If

End Sub

'When the mouse leaves the UC, we must repaint the caption (as it's no longer hovered)
Private Sub cMouseEvents_MouseLeave(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long)
    
    m_ButtonHoverIndex = -1
    
    If m_MouseInsideUC Then
        m_MouseInsideUC = False
        redrawBackBuffer
    End If
    
    'Reset the cursor
    cMouseEvents.setSystemCursor IDC_ARROW
    
End Sub

'When the mouse enters the clickable portion of the UC, we must repaint the caption (to reflect its hovered state)
Private Sub cMouseEvents_MouseMoveCustom(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long)
    
    'If the mouse is over the relevant portion of the user control, display the cursor as clickable
    Dim mouseHoverIndex As Long
    mouseHoverIndex = isMouseOverButton(x, y)
    
    'Only refresh the control if the hover value has changed
    If mouseHoverIndex <> m_ButtonHoverIndex Then
    
        m_ButtonHoverIndex = mouseHoverIndex
    
        'If the mouse is not currently hovering a button, set a default arrow cursor and exit
        If mouseHoverIndex = -1 Then
        
            cMouseEvents.setSystemCursor IDC_ARROW
        
            'Repaint the control as necessary
            If m_MouseInsideUC Then m_MouseInsideUC = False
            redrawBackBuffer
            
        Else
        
            cMouseEvents.setSystemCursor IDC_HAND
        
            'Repaint the control as necessary
            If Not m_MouseInsideUC Then m_MouseInsideUC = True
            redrawBackBuffer
            
        End If
    
    End If
    
End Sub

'See if the mouse is over the clickable portion of the control
Private Function isMouseOverButton(ByVal mouseX As Single, ByVal mouseY As Single) As Long
    
    'Search each set of button coords, looking for a match
    Dim i As Long
    For i = 0 To m_numOfButtons - 1
    
        If Math_Functions.isPointInRect(mouseX, mouseY, m_Buttons(i).btBounds) Then
            isMouseOverButton = i
            Exit Function
        End If
    
    Next i
    
    'No match was found; return -1
    isMouseOverButton = -1

End Function

'hWnds aren't exposed by default
Public Property Get hWnd() As Long
Attribute hWnd.VB_UserMemId = -515
    hWnd = UserControl.hWnd
End Property

'Container hWnd must be exposed for external tooltip handling
Public Property Get containerHwnd() As Long
    containerHwnd = UserControl.containerHwnd
End Property

'The most relevant part of this control is this ListIndex property, which just like listboxes, controls which button in the strip
' is currently pressed.
Public Property Get ListIndex() As Long
    ListIndex = m_ButtonIndex
End Property

Public Property Let ListIndex(ByVal newIndex As Long)
    
    'Update our internal value tracker
    If m_ButtonIndex <> newIndex Then
    
        m_ButtonIndex = newIndex
        PropertyChanged "ListIndex"
        
        'Redraw the control; it's important to do this *before* raising the associated event, to maintain an impression of max responsiveness
        redrawBackBuffer
        
        'Notify the user of the change by raising the CLICK event
        RaiseEvent Click(newIndex)
        
    End If
    
End Property

'ListCount is necessary for the command bar's "Randomize" feature
Public Property Get ListCount() As Long
    ListCount = m_numOfButtons
End Property

'To simplify translation handling, this public sub is used to add buttons to the UC.  An optional index can also be specified.
Public Sub AddItem(ByVal srcString As String, Optional ByVal itemIndex As Long = -1)

    'If an index was not requested, force the index to the current number of parameters.
    If itemIndex = -1 Then itemIndex = m_numOfButtons
    
    'Increase the button count and resize the array to match
    m_numOfButtons = m_numOfButtons + 1
    ReDim Preserve m_Buttons(0 To m_numOfButtons - 1) As buttonEntry
    
    'Shift all buttons above this one upward, as necessary.
    If itemIndex < m_numOfButtons - 1 Then
    
        Dim i As Long
        For i = m_numOfButtons - 1 To itemIndex Step -1
            m_Buttons(i) = m_Buttons(i - 1)
        Next i
    
    End If
    
    'Copy the new button into place
    m_Buttons(itemIndex).btCaptionEn = srcString
    
    'We must also determine a translated caption, if any
    If Not (g_Language Is Nothing) Then
    
        If g_Language.translationActive Then
            m_Buttons(itemIndex).btCaptionTranslated = g_Language.TranslateMessage(m_Buttons(itemIndex).btCaptionEn)
        Else
            m_Buttons(itemIndex).btCaptionTranslated = m_Buttons(itemIndex).btCaptionEn
        End If
    
    Else
        m_Buttons(itemIndex).btCaptionTranslated = m_Buttons(itemIndex).btCaptionEn
    End If
    
    'Erase any button references
    Set m_Buttons(i).btImage = Nothing
    Set m_Buttons(i).btImageDisabled = Nothing
    Set m_Buttons(i).btImageHover = Nothing
    
    'Before we can redraw the control, we need to recalculate all button positions - do that now!
    updateControlSize

End Sub

'Assign a DIB to a button entry.  Disabled and hover states are automatically generated.
Public Sub AssignImageToItem(ByVal itemIndex As Long, Optional ByVal resName As String = "", Optional ByRef srcDIB As pdDIB)
    
    'Load the requested resource DIB, as necessary
    If Len(resName) <> 0 Then loadResourceToDIB resName, srcDIB
    
    With m_Buttons(itemIndex)
        
        'Start by making a copy of the source DIB
        Set .btImage = New pdDIB
        .btImage.createFromExistingDIB srcDIB
        
        'Next, create a grayscale copy of the image for the disabled state
        Set .btImageDisabled = New pdDIB
        .btImageDisabled.createFromExistingDIB .btImage
        GrayscaleDIB .btImageDisabled, True
        
        'Finally, create a "glowy" hovered version of the image
        Set .btImageHover = New pdDIB
        .btImageHover.createFromExistingDIB .btImage
        ScaleDIBRGBValues .btImageHover, UC_HOVER_BRIGHTNESS, True
    
    End With

End Sub

'External functions can call this to request a redraw.  This is helpful for live-updating theme settings, as in the Preferences dialog,
' and/or retranslating all button captions against the current language.
Public Sub updateAgainstCurrentTheme()
    
    'Determine if translations are active.  If they are, retrieve translated captions for all buttons within the control.
    If g_IsProgramRunning Then
        
        'See if translations are necessary.
        Dim isTranslationActive As Boolean
            
        If Not (g_Language Is Nothing) Then
            If g_Language.translationActive Then
                isTranslationActive = True
            Else
                isTranslationActive = False
            End If
        Else
            isTranslationActive = False
        End If
        
        'Apply the new translations, if any.
        Dim i As Long
        For i = 0 To m_numOfButtons - 1
            If isTranslationActive Then
                m_Buttons(i).btCaptionTranslated = g_Language.TranslateMessage(m_Buttons(i).btCaptionEn)
            Else
                m_Buttons(i).btCaptionTranslated = m_Buttons(i).btCaptionEn
            End If
        Next i
        
        'In the future, themes may also result in font changes.  As such, recreate the font object, just to be safe.
        refreshFont
        
    End If
        
    'Because translations will change text layout, we need to recalculate font metrics prior to redrawing the button
    updateControlSize
    
End Sub

'When the control receives focus, if the focus isn't received via mouse click, display a focus rect
Private Sub UserControl_GotFocus()

    'If the mouse is *not* over the user control, assume focus was set via keyboard
    If Not m_MouseInsideUC Then
        m_FocusRectActive = m_ButtonIndex
        redrawBackBuffer
    End If

End Sub

'INITIALIZE control
Private Sub UserControl_Initialize()
    
    m_numOfButtons = 0
    
    'Initialize the internal font object
    Set curFont = New pdFont
    curFont.setTextAlignment vbLeftJustify
    
    'When not in design mode, initialize a tracker for mouse events
    If g_IsProgramRunning Then
    
        Set cMouseEvents = New pdInputMouse
        cMouseEvents.addInputTracker Me.hWnd, True, True, , True
        cMouseEvents.setSystemCursor IDC_HAND
        
        Set cKeyEvents = New pdInputKeyboard
        cKeyEvents.createKeyboardTracker "Button Strip UC", Me.hWnd, VK_RIGHT, VK_LEFT, VK_SPACE
        
        'Also start a flicker-free window painter
        Set cPainter = New pdWindowPainter
        cPainter.startPainter Me.hWnd
        
        'Create a tooltip engine
        Set toolTipManager = New pdToolTip
        
    'In design mode, initialize a base theming class, so our paint function doesn't fail
    Else
        Set g_Themer = New pdVisualThemes
    End If
    
    m_MouseInsideUC = False
    m_FocusRectActive = -1
    m_ButtonHoverIndex = -1
    
    'Update the control size parameters at least once
    updateControlSize
                
End Sub

'Set default properties
Private Sub UserControl_InitProperties()
    
    'Select the first button by default
    ListIndex = 0
    
    'Set default font properties
    m_FontBold = False
    m_FontSize = 10
    
End Sub

'When the control loses focus, erase any focus rects it may have active
Private Sub UserControl_LostFocus()

    'If a focus rect has been drawn, remove it now
    If (m_FocusRectActive >= 0) Then
        m_FocusRectActive = -1
        redrawBackBuffer
    End If

End Sub

'At run-time, painting is handled by PD's pdWindowPainter class.  In the IDE, however, we must rely on VB's internal paint event.
Private Sub UserControl_Paint()
    
    'Provide minimal painting within the designer
    If Not g_IsProgramRunning Then redrawBackBuffer
    
End Sub

Private Sub UserControl_ReadProperties(PropBag As PropertyBag)

    With PropBag
        ListIndex = .ReadProperty("ListIndex", 0)
        FontBold = .ReadProperty("FontBold", False)
        FontSize = .ReadProperty("FontSize", 10)
    End With

End Sub

'The control dynamically resizes each button to match the dimensions of their relative captions.
Private Sub UserControl_Resize()
    updateControlSize
End Sub

'Because this control automatically forces all internal buttons to identical sizes, we have to recalculate a number
' of internal sizing metrics whenever the control size changes.
Private Sub updateControlSize()

    'Remove our font object from the buffer DC, because we are about to recreate it
    curFont.releaseFromDC
    
    'Reset our back buffer, and reassign the font to it
    Set m_BackBuffer = New pdDIB
    m_BackBuffer.createBlank UserControl.ScaleWidth, UserControl.ScaleHeight, 24
    curFont.attachToDC m_BackBuffer.getDIBDC
    
    'With the buffer prepared, we now need to figure out the size of individual buttons within the strip.  While we
    ' could make these proportional to the text length of each button, I am instead taking the simpler route for now,
    ' and making all buttons the same size.
    
    'Start by calculating a set size for each button.  We will calculate these as floating-point, to avoid compounded
    ' truncation errors as we move from button to button.
    Dim buttonWidth As Double, buttonHeight As Double
    
    'Button height is easy - assume a 1px border on top and bottom, and give each button access to all space in-between.
    buttonHeight = m_BackBuffer.getDIBHeight - 2
    
    'Button width is trickier.  We have a 1px border around the whole control, and then (n-1) borders on the interior.
    If m_numOfButtons > 0 Then
        buttonWidth = (m_BackBuffer.getDIBWidth - 2 - (m_numOfButtons - 1)) / m_numOfButtons
    Else
        buttonWidth = m_BackBuffer.getDIBWidth - 2
    End If
    
    'Using these values, populate a boundary rect for each button, and store it.  (This makes the render step much faster.)
    Dim i As Long
    For i = 0 To m_numOfButtons - 1
    
        With m_Buttons(i).btBounds
            '.Left is calculated as: 1px left border, plus 1px border for any preceding buttons, plus preceding button widths
            .Left = 1 + i + (buttonWidth * i)
            .Top = 1
            .Bottom = .Top + buttonHeight
        End With
    
    Next i
    
    'Now, we're going to do something odd.  To avoid truncation errors, we're going to dynamically calculate RIGHT bounds
    ' by looping back through the array, and assigning right values to match the left value calculated for the next
    ' button in line.  The final button receives special consideration.
    If m_numOfButtons > 0 Then
    
        m_Buttons(m_numOfButtons - 1).btBounds.Right = m_BackBuffer.getDIBWidth - 2
        
        If m_numOfButtons > 1 Then
        
            For i = 1 To m_numOfButtons - 1
                m_Buttons(i - 1).btBounds.Right = m_Buttons(i).btBounds.Left - 2
            Next i
        
        End If
        
    End If
    
    'Each button now has its boundaries precisely calculated.  Next, we want to precalculate all text positioning inside
    ' each button.  Because text positioning varies by caption, we are also going to pre-cache these values, to further
    ' reduce the amount of work we need to do in the render loop.
    Dim tmpPoint As POINTAPI
    Dim strWidth As Long, strHeight As Long
    
    For i = 0 To m_numOfButtons - 1
    
        'Reset font size for this button
        m_Buttons(i).btFontSize = 0
        
        'Calculate the width of this button (which may deviate by 1px between buttons, due to integer truncation)
        buttonWidth = m_Buttons(i).btBounds.Right - m_Buttons(i).btBounds.Left
        
        'If a button has an image, we have to alter its sizing somewhat.  To make sure word-wrap is calculated correctly,
        ' remove the width of the image, plus padding, in advance.
        If Not (m_Buttons(i).btImage Is Nothing) Then
            buttonWidth = buttonWidth - (m_Buttons(i).btImage.getDIBWidth + fixDPI(IMG_TEXT_PADDING))
        End If
        
        'Retrieve the expected size of the string, in pixels
        strWidth = curFont.getWidthOfString(m_Buttons(i).btCaptionTranslated)
                
        'If the string is too long for its containing button, activate word wrap and measure again
        If strWidth > buttonWidth Then
            
            strWidth = buttonWidth
            strHeight = curFont.getHeightOfWordwrapString(m_Buttons(i).btCaptionTranslated, strWidth)
            
            'As a failsafe for ultra-long captions, restrict their size to the button size.  Truncation will (necessarily) occur.
            If (strHeight > buttonHeight) Then
                strHeight = buttonHeight
                
            'As a second failsafe, if word-wrapping didn't solve the problem (because the text is a single word, for example, as is common
            ' in German), we will forcibly set a smaller font size for this caption alone.
            ElseIf curFont.getHeightOfWordwrapString(m_Buttons(i).btCaptionTranslated, strWidth) = curFont.getHeightOfString(m_Buttons(i).btCaptionTranslated) Then
            
                'Create and initialize the shrinkFont renderer
                If (shrinkFont Is Nothing) Then
                    Set shrinkFont = New pdFont
                Else
                    shrinkFont.releaseFromDC
                End If
                
                m_Buttons(i).btFontSize = shrinkFont.getMaxFontSizeToFitStringWidth(m_Buttons(i).btCaptionTranslated, buttonWidth, m_FontSize)
                
                'The .btFontSize value now contains the font size required to render this button correctly.  In most cases, only a single button
                ' will require this kind of special treatment, so initialize a matching shrinkFont now.  (If necessary, the object will be
                ' recreated on the fly for other buttons.)
                shrinkFont.setFontBold m_FontBold
                shrinkFont.setFontSize m_Buttons(i).btFontSize
                shrinkFont.createFontObject
                
                'Also note the new string height
                strHeight = shrinkFont.getHeightOfString(m_Buttons(i).btCaptionTranslated)
                
            End If
            
        Else
            strHeight = curFont.getHeightOfString(m_Buttons(i).btCaptionTranslated)
        End If
        
        'Use the size of the string, the size of the button's image (if any), and the size of the button itself to determine
        ' optimal painting position (using top-left alignment).
        With m_Buttons(i)
        
            'No image...
            If (.btImage Is Nothing) Then
                .btCaptionRect.Left = .btBounds.Left
            
            'Image...
            Else
                
                If strWidth < buttonWidth Then
                    .btCaptionRect.Left = .btBounds.Left + m_Buttons(i).btImage.getDIBWidth + fixDPI(IMG_TEXT_PADDING)
                Else
                    .btCaptionRect.Left = .btBounds.Left + m_Buttons(i).btImage.getDIBWidth + fixDPI(IMG_TEXT_PADDING) * 2
                End If
                
                '.btCaptionRect.Left = .btBounds.Left + fixDPI(IMG_TEXT_PADDING) * 2 + m_Buttons(i).btImage.getDIBWidth
            
            End If
            
            .btCaptionRect.Top = .btBounds.Top + (buttonHeight - strHeight) \ 2
            .btCaptionRect.Right = .btBounds.Right
            .btCaptionRect.Bottom = .btBounds.Bottom
        
            'Calculate a position for the button image, if any
            If Not (.btImage Is Nothing) Then
            
                If strWidth < buttonWidth Then
                    .btImageCoords.x = .btBounds.Left + ((.btCaptionRect.Right - .btCaptionRect.Left) - strWidth) \ 2
                Else
                    .btImageCoords.x = .btBounds.Left + fixDPI(IMG_TEXT_PADDING)
                End If
                
                .btImageCoords.y = .btBounds.Top + (buttonHeight - .btImage.getDIBHeight) \ 2
            
            End If
        
        End With
        
    Next i
    
    'With all metrics successfully measured, we can now recreate the back buffer
    redrawBackBuffer
            
End Sub

Private Sub UserControl_WriteProperties(PropBag As PropertyBag)

    'Store all associated properties
    With PropBag
        .WriteProperty "ListIndex", ListIndex, 0
        .WriteProperty "FontBold", m_FontBold, False
        .WriteProperty "FontSize", m_FontSize, 10
    End With
    
End Sub

'Use this function to completely redraw the back buffer from scratch.  Note that this is computationally expensive compared to just flipping the
' existing buffer to the screen, so only redraw the backbuffer if the control state has somehow changed.
Private Sub redrawBackBuffer()
    
    'Start by erasing the back buffer
    If g_IsProgramRunning Then
        GDI_Plus.GDIPlusFillDIBRect m_BackBuffer, 0, 0, m_BackBuffer.getDIBWidth, m_BackBuffer.getDIBHeight, g_Themer.getThemeColor(PDTC_BACKGROUND_DEFAULT), 255
    Else
        m_BackBuffer.createBlank m_BackBuffer.getDIBWidth, m_BackBuffer.getDIBHeight, 24, RGB(255, 255, 255)
        curFont.attachToDC m_BackBuffer.getDIBDC
    End If
    
    'Colors used throughout this paint function are determined primarily control enablement
    Dim btnColorActiveBorder As Long, btnColorActiveFill As Long
    Dim btnColorInactiveBorder As Long, btnColorInactiveFill As Long
    Dim fontColorActive As Long, fontColorInactive As Long, fontColorHover As Long
    Dim curColor As Long
    
    If Me.Enabled Then
    
        'All colors are determined by PD's central themer
        btnColorInactiveBorder = g_Themer.getThemeColor(PDTC_GRAY_DEFAULT)
        btnColorInactiveFill = g_Themer.getThemeColor(PDTC_BACKGROUND_DEFAULT)
        btnColorActiveBorder = g_Themer.getThemeColor(PDTC_ACCENT_SHADOW)
        btnColorActiveFill = g_Themer.getThemeColor(PDTC_ACCENT_DEFAULT)
        
        fontColorInactive = g_Themer.getThemeColor(PDTC_TEXT_DEFAULT)
        fontColorActive = g_Themer.getThemeColor(PDTC_TEXT_INVERT)
        fontColorHover = g_Themer.getThemeColor(PDTC_TEXT_HYPERLINK)
        
    Else
    
        btnColorInactiveBorder = g_Themer.getThemeColor(PDTC_DISABLED)
        btnColorInactiveFill = g_Themer.getThemeColor(PDTC_BACKGROUND_DEFAULT)
        btnColorActiveBorder = g_Themer.getThemeColor(PDTC_DISABLED)
        btnColorActiveFill = g_Themer.getThemeColor(PDTC_DISABLED)
        
        fontColorInactive = g_Themer.getThemeColor(PDTC_DISABLED)
        fontColorActive = g_Themer.getThemeColor(PDTC_TEXT_INVERT)
        fontColorHover = g_Themer.getThemeColor(PDTC_DISABLED)
        
    End If
    
    'A single-pixel border is always drawn around the control
    GDI_Plus.GDIPlusDrawRectOutlineToDC m_BackBuffer.getDIBDC, 0, 0, m_BackBuffer.getDIBWidth - 1, m_BackBuffer.getDIBHeight - 1, btnColorInactiveBorder, 255, 1
    
    'Next, each individual button is rendered in turn.
    If m_numOfButtons > 0 Then
    
        Dim i As Long
        For i = 0 To m_numOfButtons - 1
        
            With m_Buttons(i)
            
                'Fill the current button with its target fill color
                If i = m_ButtonIndex Then
                    curColor = btnColorActiveFill
                Else
                    curColor = btnColorInactiveFill
                End If
                
                GDI_Plus.GDIPlusFillDIBRect m_BackBuffer, .btBounds.Left, .btBounds.Top, .btBounds.Right - .btBounds.Left + 1, .btBounds.Bottom - .btBounds.Top, curColor
                
                'For performance reasons, we only render right borders
                If i < (m_numOfButtons - 1) Then
                    GDI_Plus.GDIPlusDrawLineToDC m_BackBuffer.getDIBDC, .btBounds.Right + 1, 0, .btBounds.Right + 1, m_BackBuffer.getDIBHeight, btnColorInactiveBorder, 255, 1
                End If
                
                'Disable the next block of rendering if the control is disabled.
                If Me.Enabled Then
                
                    'If this is the active button, paint it with a special border.
                    If i = m_ButtonIndex Then
                        GDI_Plus.GDIPlusDrawRectOutlineToDC m_BackBuffer.getDIBDC, .btBounds.Left - 1, .btBounds.Top - 1, .btBounds.Right + 1, .btBounds.Bottom, btnColorActiveBorder, 255, 1
                    End If
                    
                    'If this button has received focus via keyboard, paint it with a special interior border
                    If i = m_FocusRectActive Then
                        GDI_Plus.GDIPlusDrawRectOutlineToDC m_BackBuffer.getDIBDC, .btBounds.Left + 2, .btBounds.Top + 2, .btBounds.Right - 2, .btBounds.Bottom - 3, btnColorActiveBorder, 255, 1
                    End If
                    
                End If
                
                'Paint the caption
                If i = m_ButtonIndex Then
                    curColor = fontColorActive
                Else
                    If i = m_ButtonHoverIndex Then
                        curColor = fontColorHover
                    Else
                        curColor = fontColorInactive
                    End If
                End If
                
                If .btFontSize = 0 Then
                    curFont.setFontColor curColor
                    curFont.drawCenteredTextToRect .btCaptionTranslated, .btCaptionRect
                Else
                
                    'Release the main font object
                    curFont.releaseFromDC
                
                    'Recreate shrinkFont as necessary
                    If shrinkFont.getFontSize <> .btFontSize Then
                        shrinkFont.setFontSize .btFontSize
                        shrinkFont.createFontObject
                    End If
                    
                    'Select shrinkFont into the DC and render the text accordingly
                    shrinkFont.attachToDC m_BackBuffer.getDIBDC
                    shrinkFont.setFontColor curColor
                    shrinkFont.drawCenteredTextToRect .btCaptionTranslated, .btCaptionRect
                    
                    'Restore curFont
                    shrinkFont.releaseFromDC
                    curFont.attachToDC m_BackBuffer.getDIBDC
                    
                End If
                
                'Paint the button image, if any
                If Not (.btImage Is Nothing) Then
                    
                    If Me.Enabled Then
                    
                        If i = m_ButtonHoverIndex Then
                            .btImageHover.alphaBlendToDC m_BackBuffer.getDIBDC, 255, .btImageCoords.x, .btImageCoords.y
                        Else
                            .btImage.alphaBlendToDC m_BackBuffer.getDIBDC, 255, .btImageCoords.x, .btImageCoords.y
                        End If
                        
                    Else
                        .btImageDisabled.alphaBlendToDC m_BackBuffer.getDIBDC, 255, .btImageCoords.x, .btImageCoords.y
                    End If
                    
                End If
                
            End With
        
        Next i
        
    End If
        
    'In the designer, draw a focus rect around the control; this is minimal feedback required for positioning
    If Not g_IsProgramRunning Then
        
        Dim tmpRect As RECT
        With tmpRect
            .Left = 0
            .Top = 0
            .Right = m_BackBuffer.getDIBWidth
            .Bottom = m_BackBuffer.getDIBHeight
        End With
        
        DrawFocusRect m_BackBuffer.getDIBDC, tmpRect

    End If
    
    'Paint the buffer to the screen
    If g_IsProgramRunning Then cPainter.requestRepaint Else BitBlt UserControl.hDC, 0, 0, m_BackBuffer.getDIBWidth, m_BackBuffer.getDIBHeight, m_BackBuffer.getDIBDC, 0, 0, vbSrcCopy

End Sub

'Due to complex interactions between user controls and PD's translation engine, tooltips require this dedicated function.
' (IMPORTANT NOTE: the tooltip class will handle translations automatically.  Always pass the original English text!)
Public Sub assignTooltip(ByVal newTooltip As String, Optional ByVal newTooltipTitle As String, Optional ByVal newTooltipIcon As TT_ICON_TYPE = TTI_NONE)
    toolTipManager.setTooltip Me.hWnd, Me.containerHwnd, newTooltip, newTooltipTitle, newTooltipIcon
End Sub
