# o11a-web
The web client for o11a collaborative auditing

# Source Text Rendering

The o11a web client receives formatted html source text from the backend, removing the need for any front end formatting. The html recieved can be assumed to be 40 characters wide, making front end layout decisions easy.

# Navigation Breadcrumb

Given that keyboard navigation is important in this application and running through convergences requires a lot of code-jumping, a back and forward key will be very important to get back to what you were looking at before jumping. Furthermore, maybe a breadcrumb would be beneficial to see your path. Even more than a linear breadcrumb that gets overridden when you go back and then to a new spot, a tree-like breadcrumb that preserves each history branch as you go forward and backward may be very useful. As the breadcrumb grows and is presented with lots of branches, maybe there would be a way to trim all other branches but the current one to get back to a simple history.

# Pane Management

Pane management for the application will be critical for its success. Given that all source text is 40 chars, it will be easy to work with. A tiling-window (pane in this case) manager approach could work very well, where each time a new pane is opened, it is automatically fit to the screen in a grid. Instead of a mouse-based hover-centric approach to exploring the codebase, a keyboard-centric pane-split and jump approach could work very well if done right. All panes being equal, it would be interesting, so a pane that displayed the source text for a function and a pane that displayed a single expression and its discussion would be presented in the same way. For any given pane, it could be added to the pane list or the quick view modal. The list would be a more durable view of the source you are working with, laid out in a list or grid of panes for navigation between. The quick view modal would be a more ephemeral view where the pane is hovered in the center of the screen above the list view, for digging down into the source in a quick context. Good navigation between the quick view modal and list would have to be carefully considered, but I assume that as long as the quick view modal is presented, the grid would not be navigable. I think, though the list is presented differently, the quick view modal and the panes in the list will essentially behave the same because they should both implement the same branching history. The quick view modal is mainly a focused, easy-to-dismiss view of a pane.
