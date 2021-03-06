module Views.Diagram.FourLs exposing (view)

import Constants
import Models.Diagram exposing (Model, Msg(..))
import Models.Views.FourLs as FourLs exposing (FourLsItem(..))
import String
import Svg exposing (Svg, g)
import Svg.Attributes exposing (fill, transform)
import Utils
import Views.Diagram.Views as Views


view : Model -> Svg Msg
view model =
    let
        itemHeight =
            Basics.max Constants.largeItemHeight <| Utils.getCanvasHeight model

        fourLs =
            FourLs.fromItems model.items

        (FourLsItem liked) =
            fourLs.liked

        (FourLsItem learned) =
            fourLs.learned

        (FourLsItem lacked) =
            fourLs.lacked

        (FourLsItem longedFor) =
            fourLs.longedFor
    in
    g
        [ transform
            ("translate("
                ++ String.fromFloat
                    (if isInfinite <| model.x then
                        0

                     else
                        model.x
                    )
                ++ ","
                ++ String.fromFloat
                    (if isInfinite <| model.y then
                        0

                     else
                        model.y
                    )
                ++ ")"
            )
        , fill model.settings.backgroundColor
        ]
        [ Views.canvasView model.settings
            ( Constants.largeItemWidth, itemHeight )
            ( 0, 0 )
            model.selectedItem
            liked
        , Views.canvasView model.settings
            ( Constants.largeItemWidth, itemHeight )
            ( Constants.largeItemWidth - 5, 0 )
            model.selectedItem
            learned
        , Views.canvasView model.settings
            ( Constants.largeItemWidth, itemHeight + 5 )
            ( 0, itemHeight - 5 )
            model.selectedItem
            lacked
        , Views.canvasView model.settings
            ( Constants.largeItemWidth, itemHeight + 5 )
            ( Constants.largeItemWidth - 5, itemHeight - 5 )
            model.selectedItem
            longedFor
        ]
