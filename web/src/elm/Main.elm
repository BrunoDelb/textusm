module Main exposing (init, main, view)

import Api.UrlShorter as UrlShorterApi
import Browser
import Browser.Dom as Dom
import Browser.Events exposing (Visibility(..), onMouseMove, onMouseUp, onResize, onVisibilityChange)
import Browser.Navigation as Nav
import Components.Diagram as Diagram
import Components.DiagramList as DiagramList
import File exposing (name)
import File.Download as Download
import File.Select as Select
import GraphQL.Models.DiagramItem as DiagramItem
import GraphQL.Request as Request
import Graphql.Http as Http
import Html exposing (Html, div, main_)
import Html.Attributes exposing (class, style)
import Html.Events exposing (onClick)
import Html.Lazy exposing (lazy, lazy2, lazy3, lazy4, lazy5, lazy6)
import Json.Decode as D
import List.Extra exposing (getAt, removeAt, setAt, splitAt)
import Maybe.Extra exposing (isJust)
import Models.Diagram as DiagramModel
import Models.DiagramList as DiagramListModel
import Models.DiagramType as DiagramType
import Models.Model exposing (FileType(..), LoginProvider(..), Model, Msg(..), Notification(..), ShareUrl(..))
import Models.Session as Session
import Models.Settings exposing (defaultEditorSettings, defaultSettings)
import Models.Text as Text
import Models.Title as Title
import Models.Views.CustomerJourneyMap as CustomerJourneyMap
import Models.Views.ER as ER
import Ports
import RemoteData
import Route exposing (Route(..), toRoute)
import Settings exposing (settingsDecoder, settingsEncoder)
import String
import Task
import TextUSM.Enum.Diagram as Diagram
import Time
import Url as Url exposing (percentDecode)
import Utils
import Views.BottomNavigationBar as BottomNavigationBar
import Views.Editor as Editor
import Views.Empty as Empty
import Views.Header as Header
import Views.Help as Help
import Views.Menu as Menu
import Views.Notification as Notification
import Views.ProgressBar as ProgressBar
import Views.Settings as Settings
import Views.Share as Share
import Views.SplitWindow as SplitWindow
import Views.SwitchWindow as SwitchWindow


init : ( String, String ) -> Url.Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url key =
    let
        ( apiRoot, settingsJson ) =
            flags

        settings =
            D.decodeString settingsDecoder settingsJson
                |> Result.withDefault defaultSettings

        ( diagramListModel, _ ) =
            DiagramList.init Session.guest apiRoot

        ( diagramModel, _ ) =
            Diagram.init settings.storyMap

        ( model, cmds ) =
            changeRouteTo (toRoute url)
                { diagramModel = diagramModel
                , diagramListModel = diagramListModel
                , text = Text.fromString (Maybe.withDefault "" settings.text)
                , openMenu = Nothing
                , title = Title.fromString (Maybe.withDefault "" settings.title)
                , window =
                    { position = settings.position |> Maybe.withDefault 0
                    , moveStart = False
                    , moveX = 0
                    , fullscreen = False
                    }
                , share = Nothing
                , settings = settings
                , notification = Nothing
                , url = url
                , key = key
                , editorIndex = 1
                , progress = True
                , apiRoot = apiRoot
                , session = Session.guest
                , currentDiagram = settings.diagram
                , embed = Nothing
                , dropDownIndex = Nothing
                }
    in
    ( model, cmds )


view : Model -> Html Msg
view model =
    main_
        [ style "position" "relative"
        , style "width" "100vw"
        , onClick CloseMenu
        ]
        [ lazy6 Header.view model.session (toRoute model.url) model.title model.window.fullscreen model.openMenu model.text
        , lazy showNotification model.notification
        , lazy2 showProgressbar model.progress model.window.fullscreen
        , div
            [ class "main" ]
            [ lazy5 Menu.view (toRoute model.url) model.text model.diagramModel.width model.window.fullscreen model.openMenu
            , let
                mainWindow =
                    if model.diagramModel.width > 0 && Utils.isPhone model.diagramModel.width then
                        lazy4 SwitchWindow.view
                            model.diagramModel.settings.backgroundColor
                            model.editorIndex

                    else
                        lazy4 SplitWindow.view
                            model.diagramModel.settings.backgroundColor
                            model.window
              in
              case toRoute model.url of
                Route.List ->
                    lazy DiagramList.view model.diagramListModel |> Html.map UpdateDiagramList

                Route.Help ->
                    Help.view

                Route.SharingSettings ->
                    lazy3 sharePage (toRoute model.url) model.embed model.share

                Route.Settings ->
                    lazy2 Settings.view model.dropDownIndex model.settings

                Route.Embed diagram title path ->
                    div [ style "width" "100%", style "height" "100%", style "background-color" model.settings.storyMap.backgroundColor ]
                        [ let
                            diagramModel =
                                model.diagramModel
                          in
                          lazy Diagram.view diagramModel
                            |> Html.map UpdateDiagram
                        , lazy4 BottomNavigationBar.view model.settings diagram title path
                        ]

                _ ->
                    mainWindow
                        Editor.view
                        (let
                            diagramModel =
                                model.diagramModel
                         in
                         lazy Diagram.view diagramModel
                            |> Html.map UpdateDiagram
                        )
            ]
        ]


sharePage : Route -> Maybe String -> Maybe ShareUrl -> Html Msg
sharePage route embedUrl shareUrl =
    case route of
        SharingSettings ->
            case ( shareUrl, embedUrl ) of
                ( Just (ShareUrl url), Just e ) ->
                    Share.view
                        e
                        url

                _ ->
                    Empty.view

        _ ->
            Empty.view


main : Program ( String, String ) Model Msg
main =
    Browser.application
        { init = init
        , update = update
        , view =
            \m ->
                { title = Title.toString m.title ++ " | TextUSM"
                , body = [ view m ]
                }
        , subscriptions = subscriptions
        , onUrlChange = UrlChanged
        , onUrlRequest = LinkClicked
        }


showProgressbar : Bool -> Bool -> Html Msg
showProgressbar show fullscreen =
    if show then
        ProgressBar.view

    else if not fullscreen then
        div [ style "height" "4px", style "background" "#273037" ] []

    else
        Empty.view


showNotification : Maybe Notification -> Html Msg
showNotification notify =
    case notify of
        Just notification ->
            Notification.view notification

        Nothing ->
            Empty.view



-- Update


changeRouteTo : Route -> Model -> ( Model, Cmd Msg )
changeRouteTo route model =
    let
        getCmds : List (Cmd Msg) -> Cmd Msg
        getCmds cmds =
            Cmd.batch (Task.perform Init Dom.getViewport :: cmds)

        changeDiagramType : Diagram.Diagram -> ( Model, Cmd Msg )
        changeDiagramType type_ =
            let
                diagramModel =
                    model.diagramModel

                newDiagramModel =
                    { diagramModel | diagramType = type_ }
            in
            ( { model | diagramModel = newDiagramModel }
            , getCmds
                [ if type_ == Diagram.Markdown then
                    Ports.setEditorLanguage "markdown"

                  else
                    Ports.setEditorLanguage "userStoryMap"
                ]
            )
    in
    case route of
        Route.List ->
            if RemoteData.isNotAsked model.diagramListModel.diagramList || List.isEmpty (RemoteData.withDefault [] model.diagramListModel.diagramList) then
                let
                    ( model_, cmd_ ) =
                        DiagramList.init model.session model.apiRoot
                in
                ( { model | progress = True, diagramListModel = model_ }
                , getCmds [ Ports.getDiagrams (), cmd_ |> Cmd.map UpdateDiagramList ]
                )

            else
                ( { model | progress = False }, Cmd.none )

        Route.Embed diagram title path ->
            let
                diagramModel =
                    model.diagramModel

                newDiagramModel =
                    { diagramModel
                        | diagramType =
                            DiagramType.fromString diagram
                        , showZoomControl = False
                    }
            in
            ( { model
                | window =
                    { position = model.window.position
                    , moveStart = model.window.moveStart
                    , moveX = model.window.moveX
                    , fullscreen = True
                    }
                , diagramModel = newDiagramModel
                , title = Title.fromString title
              }
            , getCmds [ Ports.decodeShareText path ]
            )

        Route.Share diagram title path ->
            let
                diagramModel =
                    model.diagramModel

                newDiagramModel =
                    { diagramModel
                        | diagramType =
                            DiagramType.fromString diagram
                    }
            in
            ( { model
                | diagramModel = newDiagramModel
                , title = Title.fromString title
              }
            , getCmds [ Ports.decodeShareText path ]
            )

        Route.UsmView settingsJson ->
            changeRouteTo (Route.View "usm" settingsJson) model

        Route.View diagram settingsJson ->
            let
                maybeSettings =
                    percentDecode settingsJson
                        |> Maybe.andThen
                            (\x ->
                                D.decodeString settingsDecoder x |> Result.toMaybe
                            )

                diagramModel =
                    model.diagramModel

                newDiagramModel =
                    { diagramModel
                        | diagramType =
                            DiagramType.fromString diagram
                    }

                updatedDiagramModel =
                    case maybeSettings of
                        Just settings ->
                            { newDiagramModel | settings = settings.storyMap, showZoomControl = False, fullscreen = True }

                        Nothing ->
                            { newDiagramModel | showZoomControl = False, fullscreen = True }
            in
            case maybeSettings of
                Just settings ->
                    ( { model
                        | settings = settings
                        , diagramModel = updatedDiagramModel
                        , window =
                            { position = model.window.position
                            , moveStart = model.window.moveStart
                            , moveX = model.window.moveX
                            , fullscreen = True
                            }
                        , text = Text.edit model.text (String.replace "\\n" "\n" (Maybe.withDefault "" settings.text))
                        , title = Title.fromString <| Maybe.withDefault "" settings.title
                      }
                    , getCmds []
                    )

                Nothing ->
                    ( model, getCmds [] )

        Route.BusinessModelCanvas ->
            changeDiagramType Diagram.BusinessModelCanvas

        Route.OpportunityCanvas ->
            changeDiagramType Diagram.OpportunityCanvas

        Route.FourLs ->
            changeDiagramType Diagram.Fourls

        Route.StartStopContinue ->
            changeDiagramType Diagram.StartStopContinue

        Route.Kpt ->
            changeDiagramType Diagram.Kpt

        Route.Persona ->
            changeDiagramType Diagram.UserPersona

        Route.Markdown ->
            changeDiagramType Diagram.Markdown

        Route.MindMap ->
            changeDiagramType Diagram.MindMap

        Route.ImpactMap ->
            changeDiagramType Diagram.ImpactMap

        Route.EmpathyMap ->
            changeDiagramType Diagram.EmpathyMap

        Route.UserStoryMap ->
            changeDiagramType Diagram.UserStoryMap

        Route.CustomerJourneyMap ->
            changeDiagramType Diagram.CustomerJourneyMap

        Route.SiteMap ->
            changeDiagramType Diagram.SiteMap

        Route.GanttChart ->
            changeDiagramType Diagram.GanttChart

        Route.ErDiagram ->
            changeDiagramType Diagram.ErDiagram

        Route.Kanban ->
            changeDiagramType Diagram.Kanban

        Route.Home ->
            ( model, getCmds [] )

        Route.Settings ->
            ( model, getCmds [] )

        Route.Help ->
            ( model, getCmds [] )

        Route.SharingSettings ->
            ( model, getCmds [] )


update : Msg -> Model -> ( Model, Cmd Msg )
update message model =
    case message of
        NoOp ->
            ( model, Cmd.none )

        UpdateDiagram subMsg ->
            case subMsg of
                DiagramModel.OnResize _ _ ->
                    let
                        ( model_, cmd_ ) =
                            Diagram.update subMsg model.diagramModel
                    in
                    ( { model | diagramModel = model_ }
                    , Cmd.batch
                        [ cmd_ |> Cmd.map UpdateDiagram
                        , Ports.loadEditor ( Text.toString model.text, defaultEditorSettings model.settings.editor )
                        ]
                    )

                DiagramModel.MoveItem ( fromNo, toNo ) ->
                    let
                        lines =
                            Text.lines model.text

                        from =
                            getAt fromNo lines
                                |> Maybe.withDefault ""

                        newLines =
                            removeAt fromNo lines

                        ( left, right ) =
                            splitAt
                                (if fromNo < toNo then
                                    toNo - 1

                                 else
                                    toNo
                                )
                                newLines

                        text =
                            left
                                ++ from
                                :: right
                                |> String.join "\n"
                    in
                    ( { model | text = Text.edit model.text text }
                    , Cmd.batch
                        [ Task.perform identity (Task.succeed (UpdateDiagram (DiagramModel.OnChangeText text)))
                        , Task.perform identity (Task.succeed (UpdateDiagram DiagramModel.DeselectItem))
                        , Ports.loadText text
                        ]
                    )

                DiagramModel.EndEditSelectedItem item code isComposing ->
                    if code == 13 && not isComposing then
                        let
                            lines =
                                Text.lines model.text

                            currentText =
                                getAt item.lineNo lines

                            prefix =
                                currentText
                                    |> Maybe.withDefault ""
                                    |> Utils.getSpacePrefix

                            text =
                                setAt item.lineNo (prefix ++ String.trimLeft item.text) lines
                                    |> String.join "\n"
                        in
                        ( { model | text = Text.edit model.text text }
                        , Cmd.batch
                            [ Task.perform identity (Task.succeed (UpdateDiagram (DiagramModel.OnChangeText text)))
                            , Task.perform identity (Task.succeed (UpdateDiagram DiagramModel.DeselectItem))
                            , Ports.loadText text
                            ]
                        )

                    else
                        ( model, Cmd.none )

                DiagramModel.ToggleFullscreen ->
                    let
                        window =
                            model.window

                        newWindow =
                            { window | fullscreen = not window.fullscreen }

                        ( model_, cmd_ ) =
                            Diagram.update subMsg model.diagramModel
                    in
                    ( { model | window = newWindow, diagramModel = model_ }
                    , Cmd.batch
                        [ cmd_ |> Cmd.map UpdateDiagram
                        , if newWindow.fullscreen then
                            Ports.openFullscreen ()

                          else
                            Ports.closeFullscreen ()
                        ]
                    )

                DiagramModel.OnChangeText text ->
                    let
                        ( model_, _ ) =
                            Diagram.update subMsg model.diagramModel
                    in
                    ( { model | text = Text.edit model.text text, diagramModel = model_ }, Cmd.none )

                _ ->
                    let
                        ( model_, cmd_ ) =
                            Diagram.update subMsg model.diagramModel
                    in
                    ( { model | diagramModel = model_ }, cmd_ |> Cmd.map UpdateDiagram )

        UpdateDiagramList subMsg ->
            case subMsg of
                DiagramListModel.Select diagram ->
                    if diagram.isRemote then
                        ( { model
                            | progress = False
                            , text = Text.edit model.text diagram.text
                            , title = Title.fromString diagram.title
                            , currentDiagram = Just diagram
                          }
                        , Cmd.batch
                            [ Nav.pushUrl model.key <| DiagramType.toString diagram.diagram
                            , Ports.loadText diagram.text
                            ]
                        )

                    else
                        ( { model
                            | text = Text.edit model.text diagram.text
                            , title = Title.fromString diagram.title
                            , currentDiagram = Just diagram
                          }
                        , Nav.pushUrl model.key <| DiagramType.toString diagram.diagram
                        )

                DiagramListModel.Removed (Err e) ->
                    case e of
                        Http.GraphqlError _ _ ->
                            ( model
                            , Cmd.batch
                                [ Utils.delay 3000 OnCloseNotification
                                , Utils.showErrorMessage
                                    "Failed remove diagram."
                                ]
                            )

                        Http.HttpError Http.Timeout ->
                            ( model
                            , Cmd.batch
                                [ Utils.delay 3000 OnCloseNotification
                                , Utils.showErrorMessage
                                    "Request timeout."
                                ]
                            )

                        Http.HttpError Http.NetworkError ->
                            ( model
                            , Cmd.batch
                                [ Utils.delay 3000 OnCloseNotification
                                , Utils.showErrorMessage
                                    "Network error."
                                ]
                            )

                        Http.HttpError _ ->
                            ( model
                            , Cmd.batch
                                [ Utils.delay 3000 OnCloseNotification
                                , Utils.showErrorMessage
                                    "Failed remove diagram."
                                ]
                            )

                DiagramListModel.GotDiagrams (Err _) ->
                    ( model
                    , Cmd.batch
                        [ Utils.delay 3000 OnCloseNotification
                        , Utils.showErrorMessage
                            "Failed remove diagram."
                        ]
                    )

                _ ->
                    let
                        ( model_, cmd_ ) =
                            DiagramList.update subMsg model.diagramListModel
                    in
                    ( { model | progress = False, diagramListModel = model_ }
                    , cmd_ |> Cmd.map UpdateDiagramList
                    )

        Init window ->
            let
                ( model_, _ ) =
                    Diagram.update (DiagramModel.Init model.diagramModel.settings window (Text.toString model.text)) model.diagramModel
            in
            ( { model
                | diagramModel = model_
                , progress = False
                , text = Text.saved model.text
              }
            , Ports.loadEditor ( Text.toString model.text, defaultEditorSettings model.settings.editor )
            )

        DownloadCompleted ( x, y ) ->
            let
                diagramModel =
                    model.diagramModel

                newDiagramModel =
                    { diagramModel | x = toFloat x, y = toFloat y, matchParent = False }
            in
            ( { model | diagramModel = newDiagramModel }, Cmd.none )

        Download fileType ->
            if fileType == DDL then
                let
                    ( _, tables ) =
                        ER.fromItems model.diagramModel.items

                    ddl =
                        List.map ER.tableToString tables
                            |> String.join "\n"
                in
                ( model, Download.string (Title.toString model.title ++ ".sql") "text/plain" ddl )

            else if fileType == MarkdownTable then
                ( model, Download.string (Title.toString model.title ++ ".md") "text/plain" (CustomerJourneyMap.toString (CustomerJourneyMap.fromItems model.diagramModel.items)) )

            else
                let
                    ( width, height ) =
                        Utils.getCanvasSize model.diagramModel

                    diagramModel =
                        model.diagramModel

                    newDiagramModel =
                        { diagramModel | x = 0, y = 0, matchParent = True }

                    ( sub, extension ) =
                        case fileType of
                            Png ->
                                ( Ports.downloadPng, ".png" )

                            Pdf ->
                                ( Ports.downloadPdf, ".pdf" )

                            Svg ->
                                ( Ports.downloadSvg, ".svg" )

                            HTML ->
                                ( Ports.downloadHtml, ".html" )

                            _ ->
                                ( Ports.downloadSvg, ".svg" )
                in
                ( { model | diagramModel = newDiagramModel }
                , sub
                    { width = width
                    , height = height
                    , id = "usm"
                    , title = Title.toString model.title ++ extension
                    , x = 0
                    , y = 0
                    , text = Text.toString model.text
                    , diagramType = DiagramType.toString model.diagramModel.diagramType
                    }
                )

        StartDownload info ->
            ( model, Cmd.batch [ Download.string (Title.toString model.title ++ info.extension) info.mimeType info.content, Task.perform identity (Task.succeed CloseMenu) ] )

        OpenMenu menu ->
            ( { model | openMenu = Just menu }, Cmd.none )

        CloseMenu ->
            ( { model | openMenu = Nothing }, Cmd.none )

        FileSelect ->
            ( model, Select.file [ "text/plain", "text/markdown" ] FileSelected )

        FileSelected file ->
            ( { model | title = Title.fromString (File.name file) }, Utils.fileLoad file FileLoaded )

        FileLoaded text ->
            ( model, Cmd.batch [ Task.perform identity (Task.succeed (UpdateDiagram (DiagramModel.OnChangeText text))), Ports.loadText text ] )

        SaveToFileSystem ->
            let
                title =
                    Title.toString model.title
            in
            ( model, Download.string title "text/plain" (Text.toString model.text) )

        Save ->
            let
                isRemote =
                    Session.isSignedIn model.session

                diagramListModel =
                    model.diagramListModel

                newDiagramListModel =
                    { diagramListModel | diagramList = RemoteData.NotAsked }
            in
            if Title.isUntitled model.title then
                let
                    ( model_, cmd_ ) =
                        update StartEditTitle model
                in
                ( model_, cmd_ )

            else
                let
                    title =
                        Title.toString model.title
                in
                ( { model
                    | notification =
                        if not isRemote then
                            Just (Info ("Successfully \"" ++ title ++ "\" saved."))

                        else
                            Nothing
                    , diagramListModel = newDiagramListModel
                    , text = Text.edit model.text (Text.toString model.text)
                  }
                , Cmd.batch
                    [ Ports.saveDiagram <|
                        DiagramItem.encoder
                            { id = Maybe.andThen .id model.currentDiagram
                            , title = title
                            , text = Text.toString model.text
                            , thumbnail = Nothing
                            , diagram = model.diagramModel.diagramType
                            , isRemote = isRemote
                            , isPublic = False
                            , isBookmark = False
                            , updatedAt = Time.millisToPosix 0
                            , createdAt = Time.millisToPosix 0
                            }
                    , if isRemote then
                        Cmd.none

                      else
                        Utils.delay 3000 OnCloseNotification
                    ]
                )

        SaveToLocalCompleted diagramJson ->
            let
                result =
                    D.decodeString DiagramItem.decoder diagramJson
            in
            case result of
                Ok item ->
                    ( { model | currentDiagram = Just item }, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        SaveToRemote diagramJson ->
            let
                result =
                    D.decodeString DiagramItem.decoder diagramJson
                        |> Result.andThen
                            (\diagram ->
                                Ok
                                    (Request.save { url = model.apiRoot, idToken = Session.getIdToken model.session } (DiagramItem.toInputItem diagram)
                                        |> Task.map (\_ -> diagram)
                                    )
                            )
            in
            case result of
                Ok saveTask ->
                    ( { model | progress = True }, Task.attempt SaveToRemoteCompleted saveTask )

                Err _ ->
                    ( { model | progress = True }
                    , Cmd.batch
                        [ Utils.delay 3000
                            OnCloseNotification
                        , Utils.showWarningMessage ("Successfully \"" ++ Title.toString model.title ++ "\" saved.")
                        ]
                    )

        SaveToRemoteCompleted (Err _) ->
            let
                item =
                    { id = Nothing
                    , title = Title.toString model.title
                    , text = Text.toString model.text
                    , thumbnail = Nothing
                    , diagram = model.diagramModel.diagramType
                    , isRemote = False
                    , isPublic = False
                    , isBookmark = False
                    , updatedAt = Time.millisToPosix 0
                    , createdAt = Time.millisToPosix 0
                    }
            in
            ( { model
                | progress = False
                , currentDiagram = Just item
              }
            , Cmd.batch
                [ Utils.delay 3000
                    OnCloseNotification
                , Utils.showWarningMessage ("Successfully \"" ++ Title.toString model.title ++ "\" saved.")
                , Ports.saveDiagram <| DiagramItem.encoder item
                ]
            )

        SaveToRemoteCompleted (Ok diagram) ->
            ( { model | currentDiagram = Just diagram, progress = False }
            , Cmd.batch
                [ Utils.delay 3000 OnCloseNotification
                , Utils.showInfoMessage ("Successfully \"" ++ Title.toString model.title ++ "\" saved.")
                ]
            )

        SelectAll id ->
            ( model, Ports.selectTextById id )

        Shortcuts x ->
            if x == "save" then
                update Save model

            else if x == "open" then
                update GetDiagrams model

            else
                ( model, Cmd.none )

        StartEditTitle ->
            ( { model | title = Title.edit model.title }
            , Task.attempt
                (\_ -> NoOp)
              <|
                Dom.focus "title"
            )

        EndEditTitle code isComposing ->
            if code == 13 && not isComposing then
                ( { model | title = Title.view model.title }, Cmd.none )

            else
                ( model, Cmd.none )

        EditTitle title ->
            ( { model | title = Title.edit <| Title.fromString title }, Cmd.none )

        NavRoute route ->
            ( model, Nav.pushUrl model.key (Route.toString route) )

        NavBack ->
            ( model, Nav.back model.key 1 )

        OnVisibilityChange visible ->
            if model.window.fullscreen then
                ( model, Cmd.none )

            else if visible == Hidden then
                let
                    storyMap =
                        model.settings.storyMap

                    newStoryMap =
                        { storyMap | font = model.settings.font }

                    newSettings =
                        { position = Just model.window.position
                        , font = model.settings.font
                        , diagramId = Maybe.andThen .id model.currentDiagram
                        , storyMap = newStoryMap
                        , text = Just (Text.toString model.text)
                        , title =
                            Just <| Title.toString model.title
                        , editor = model.settings.editor
                        , diagram = model.currentDiagram
                        }
                in
                ( { model | settings = newSettings }
                , Ports.saveSettings (settingsEncoder newSettings)
                )

            else
                ( model, Cmd.none )

        OnStartWindowResize x ->
            ( { model
                | window =
                    { position = model.window.position
                    , moveStart = True
                    , moveX = x
                    , fullscreen = model.window.fullscreen
                    }
              }
            , Cmd.none
            )

        Stop ->
            ( { model
                | window =
                    { position = model.window.position
                    , moveStart = False
                    , moveX = model.window.moveX
                    , fullscreen = model.window.fullscreen
                    }
              }
            , Cmd.none
            )

        OnWindowResize x ->
            ( { model
                | window =
                    { position = model.window.position + x - model.window.moveX
                    , moveStart = True
                    , moveX = x
                    , fullscreen = model.window.fullscreen
                    }
              }
            , Ports.layoutEditor 0
            )

        OnCurrentShareUrl ->
            ( { model | progress = True }
            , Cmd.batch
                [ Ports.encodeShareText
                    { diagramType =
                        DiagramType.toString model.diagramModel.diagramType
                    , title = Just <| Title.toString model.title
                    , text = Text.toString model.text
                    }
                ]
            )

        GetShortUrl (Err e) ->
            ( { model | progress = False }
            , Cmd.batch
                [ Task.perform identity (Task.succeed (OnNotification (Error ("Error. " ++ Utils.httpErrorToString e))))
                , Utils.delay 3000 OnCloseNotification
                ]
            )

        GetShortUrl (Ok res) ->
            ( { model
                | progress = False
                , share = Just (ShareUrl res.shortLink)
              }
            , Nav.pushUrl model.key (Route.toString Route.SharingSettings)
            )

        OnShareUrl shareInfo ->
            ( model
            , Ports.encodeShareText shareInfo
            )

        OnNotification notification ->
            ( { model | notification = Just notification }, Cmd.none )

        OnAutoCloseNotification notification ->
            ( { model | notification = Just notification }, Utils.delay 3000 OnCloseNotification )

        OnCloseNotification ->
            ( { model | notification = Nothing }, Cmd.none )

        OnEncodeShareText path ->
            let
                shareUrl =
                    "https://app.textusm.com/share" ++ path

                embedUrl =
                    "https://app.textusm.com/embed" ++ path
            in
            ( { model | embed = Just embedUrl }, Task.attempt GetShortUrl (UrlShorterApi.urlShorter (Session.getIdToken model.session) model.apiRoot shareUrl) )

        OnDecodeShareText text ->
            ( model, Task.perform identity (Task.succeed (FileLoaded text)) )

        WindowSelect tab ->
            ( { model | editorIndex = tab }, Ports.layoutEditor 100 )

        LinkClicked urlRequest ->
            case urlRequest of
                Browser.Internal url ->
                    ( model, Nav.pushUrl model.key (Url.toString url) )

                Browser.External href ->
                    ( model, Nav.load href )

        UrlChanged url ->
            let
                updatedModel =
                    { model | url = url }
            in
            changeRouteTo (toRoute url) updatedModel

        GetDiagrams ->
            ( { model | progress = True }, Nav.pushUrl model.key (Route.toString Route.List) )

        UpdateSettings getSetting value ->
            let
                settings =
                    getSetting value

                diagramModel =
                    model.diagramModel

                newDiagramModel =
                    { diagramModel | settings = settings.storyMap }
            in
            ( { model | dropDownIndex = Nothing, settings = settings, diagramModel = newDiagramModel }, Cmd.none )

        SignIn provider ->
            ( { model | progress = True }
            , Ports.signIn <|
                case provider of
                    Google ->
                        "Google"

                    Github ->
                        "Github"
            )

        SignOut ->
            ( { model | session = Session.guest, currentDiagram = Nothing }, Ports.signOut () )

        OnAuthStateChanged (Just user) ->
            ( { model | session = Session.signIn user, progress = False }, Cmd.none )

        OnAuthStateChanged Nothing ->
            ( { model | session = Session.guest, progress = False }, Cmd.none )

        ToggleDropDownList id ->
            let
                activeIndex =
                    if (model.dropDownIndex |> Maybe.withDefault "") == id then
                        Nothing

                    else
                        Just id
            in
            ( { model | dropDownIndex = activeIndex }, Cmd.none )

        Progress visible ->
            ( { model | progress = visible }, Cmd.none )

        New type_ ->
            let
                ( text_, route_ ) =
                    case type_ of
                        Diagram.UserStoryMap ->
                            ( "", Route.UserStoryMap )

                        Diagram.BusinessModelCanvas ->
                            ( "👥 Key Partners\n📊 Customer Segments\n🎁 Value Proposition\n✅ Key Activities\n🚚 Channels\n💰 Revenue Streams\n🏷️ Cost Structure\n💪 Key Resources\n💙 Customer Relationships", Route.BusinessModelCanvas )

                        Diagram.OpportunityCanvas ->
                            ( "Problems\nSolution Ideas\nUsers and Customers\nSolutions Today\nBusiness Challenges\nHow will Users use Solution?\nUser Metrics\nAdoption Strategy\nBusiness Benefits and Metrics\nBudget", Route.OpportunityCanvas )

                        Diagram.Fourls ->
                            ( "Liked\nLearned\nLacked\nLonged for", Route.FourLs )

                        Diagram.StartStopContinue ->
                            ( "Start\nStop\nContinue", Route.StartStopContinue )

                        Diagram.Kpt ->
                            ( "K\nP\nT", Route.Kpt )

                        Diagram.UserPersona ->
                            ( "Name\n    https://app.textusm.com/images/logo.svg\nWho am i...\nThree reasons to use your product\nThree reasons to buy your product\nMy interests\nMy personality\nMy Skills\nMy dreams\nMy relationship with technology", Route.Persona )

                        Diagram.Markdown ->
                            ( "", Route.Markdown )

                        Diagram.MindMap ->
                            ( "", Route.MindMap )

                        Diagram.ImpactMap ->
                            ( "", Route.ImpactMap )

                        Diagram.EmpathyMap ->
                            ( "SAYS\nTHINKS\nDOES\nFEELS", Route.EmpathyMap )

                        Diagram.CustomerJourneyMap ->
                            ( "Header\n    Task\n    Questions\n    Touchpoints\n    Emotions\n    Influences\n    Weaknesses\nDiscover\n    Task\n    Questions\n    Touchpoints\n    Emotions\n    Influences\n    Weaknesses\nResearch\n    Task\n    Questions\n    Touchpoints\n    Emotions\n    Influences\n    Weaknesses\nPurchase\n    Task\n    Questions\n    Touchpoints\n    Emotions\n    Influences\n    Weaknesses\nDelivery\n    Task\n    Questions\n    Touchpoints\n    Emotions\n    Influences\n    Weaknesses\nPost-Sales\n    Task\n    Questions\n    Touchpoints\n    Emotions\n    Influences\n    Weaknesses\n", Route.CustomerJourneyMap )

                        Diagram.SiteMap ->
                            ( "", Route.SiteMap )

                        Diagram.GanttChart ->
                            ( "2019-12-26,2020-01-31\n    title1\n        subtitle1\n            2019-12-26, 2019-12-31\n    title2\n        subtitle2\n            2019-12-31, 2020-01-04\n", Route.GanttChart )

                        Diagram.ErDiagram ->
                            ( "relations\n    # one to one\n    Table1 - Table2\n    # one to many\n    Table1 < Table3\ntables\n    Table1\n        id int pk auto_increment\n        name varchar(255) unique\n        rate float null\n        value double not null\n        values enum(value1,value2) not null\n    Table2\n        id int pk auto_increment\n        name double unique\n    Table3\n        id int pk auto_increment\n        name varchar(255) index\n", Route.ErDiagram )

                        Diagram.Kanban ->
                            ( "TODO\nDOING\nDONE", Route.Kanban )

                displayText =
                    if Text.isEmpty model.text then
                        Text.edit model.text text_

                    else
                        model.text
            in
            ( { model
                | title = Title.untitled
                , text = displayText
                , currentDiagram = Nothing
              }
            , Cmd.batch [ Ports.loadText (Text.toString displayText), Nav.pushUrl model.key (Route.toString route_) ]
            )



-- Ports


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        ([ Ports.changeText (\text -> UpdateDiagram (DiagramModel.OnChangeText text))
         , Ports.startDownload StartDownload
         , Ports.gotLocalDiagramJson (\json -> UpdateDiagramList (DiagramListModel.GotLocalDiagramJson json))
         , Ports.removedDiagram (\_ -> UpdateDiagramList DiagramListModel.Reload)
         , onVisibilityChange OnVisibilityChange
         , onResize (\width height -> UpdateDiagram (DiagramModel.OnResize width height))
         , onMouseUp (D.succeed (UpdateDiagram DiagramModel.Stop))
         , Ports.onEncodeShareText OnEncodeShareText
         , Ports.onDecodeShareText OnDecodeShareText
         , Ports.shortcuts Shortcuts
         , Ports.onNotification (\n -> OnAutoCloseNotification (Info n))
         , Ports.onErrorNotification (\n -> OnAutoCloseNotification (Error n))
         , Ports.onWarnNotification (\n -> OnAutoCloseNotification (Warning n))
         , Ports.onAuthStateChanged OnAuthStateChanged
         , Ports.saveToRemote SaveToRemote
         , Ports.removeRemoteDiagram (\diagram -> UpdateDiagramList <| DiagramListModel.RemoveRemote diagram)
         , Ports.downloadCompleted DownloadCompleted
         , Ports.progress Progress
         , Ports.saveToLocalCompleted SaveToLocalCompleted
         ]
            ++ (if model.window.moveStart then
                    [ onMouseUp (D.succeed Stop)
                    , onMouseMove (D.map OnWindowResize pageX)
                    ]

                else
                    [ Sub.none ]
               )
        )


pageX : D.Decoder Int
pageX =
    D.field "pageX" D.int
