
module ULOL
  module Indoor3DGmlModeler
    module IndoorNavi

      # Abstract
      class NavigableSpace < IndoorCore::CellSpace
      end

      # Room
      class GeneralSpace < NavigableSpace
      end

      # Stair, ES, EV
      class TransferSpace < NavigableSpace
      end

      # Door, Gate
      class TransitionSpace < TransferSpace
      end

      # Corrider
      class ConnectionSpace < TransferSpace
      end

      # Enterance
      class AnchorSpace < TransferSpace
      end

      #---------------------------------------------#

      # class RouteNode; end
      # class RouteSegment; end
      # class Route; end

      #---------------------------------------------#

      # class NaviableBoundary < IndoorCore::CellSpaceBoundary ; end
      # class TransferBoundary < NaviableBoundary ; end
      # class ConnectionBoundary < TransferBoundary ; end
      # class AnchorBoundary < TransferBoundary ; end

    end 
  end
end