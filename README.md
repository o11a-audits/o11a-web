# o11a-web
The web client for o11a collaborative auditing

# Source Text Rendering

The o11a web client has a dynamic source text renderer, where it takes HTML output from the backend formatter and renders it based on the container's width. This way, the source text can always fit in its container without horizontal scrolling. This allows the web client to be flexible in how it displays source text to the user and provides for multi-pane views.

The dynamic formatting works as follows: The source text is rendered in a container. A JavaScript function initializes an internal state with a counter of 0 and an empty list of prior splits. It then runs a check on scrollWidth vs clientWidth to determine if the source text is overflowing horizontally. This check is attached to a resize event and will continually shrink or grow the source text as the container shrinks or grows. 

The overflow check is as follows:

If the text is overflowing:

1. Search for the .split<count> elements and their text to a newline to split the line. If none exist, do nothing further
2. Increment the counter by 1, indicating that it has split the element at that rank
3. Save the width that triggered this overflow, along with the split rank that the width triggered
4. Run again until the text is not overflowing
 
If the text is not overflowing:

1. Check if the width is greater than the most recent (smallest) width that caused an overflow. If it is not, do nothing further
3. Search for the .split<count> elements, changing their text to a space
4. Decrement the counter by 1.
5. Run again until the width is not greater than the most recent width that caused an overflow

# Navigation Breadcrumb

Given that keyboard navigation is important in this application and running through convergences requires a lot of code-jumping, a back and forward key will be very important to get back to what you were looking at before jumping. Furthermore, maybe a breadcrumb would be beneficial to see your path. Even more than a linear breadcrumb that gets overridden when you go back and then to a new spot, a tree-like breadcrumb that preserves each history branch as you go forward and backward may be very useful. As the breadcrumb grows and is presented with lots of branches, maybe there would be a way to trim all other branches but the current one to get back to a simple history.

# Pane Management

Pane management for the application will be critical for its success. Given that all source text is 40 chars, it will be easy to work with. A tiling-window (pane in this case) manager approach could work very well, where each time a new pane is opened, it is automatically fit to the screen in a grid. Instead of a mouse-based hover-centric approach to exploring the codebase, a keyboard-centric pane-split and jump approach could work very well if done right. All panes being equal, it would be interesting, so a pane that displayed the source text for a function and a pane that displayed a single expression and its discussion would be presented in the same way. For any given pane, it could be added to the pane list or the quick view modal. The list would be a more durable view of the source you are working with, laid out in a list or grid of panes for navigation between. The quick view modal would be a more ephemeral view where the pane is hovered in the center of the screen above the list view, for digging down into the source in a quick context. Good navigation between the quick view modal and list would have to be carefully considered, but I assume that as long as the quick view modal is presented, the grid would not be navigable. I think, though the list is presented differently, the quick view modal and the panes in the list will essentially behave the same because they should both implement the same branching history. The quick view modal is mainly a focused, easy-to-dismiss view of a pane.
