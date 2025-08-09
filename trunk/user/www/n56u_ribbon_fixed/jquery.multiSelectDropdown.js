/**
 * Dropdown Library with selected items display
 * created for https://github.com/nilabsent/padavan-ng
 *
 * Version: beta
 * Author:  nil
 * Licence: licenced under MIT licence (http://opensource.org/licenses/MIT)
*/
(function($){
  $.fn.multiSelectDropdown = function(methodOrOptions){
    const methods = {
      init: function(options){
        const settings = $.extend({
          placeholder: 'Add item...',
          items: [],
          onChange: null,
          allowDelete: true,
          allowAdd: true,
          removeSpaces: false,
          addSuggestionText: 'Add',
          allowedItems: null,
          allowedAlert: '',
          width: null
        }, options);

        return this.each(function(){
          const $wrapper = $(this).addClass('msd-dropdown');
          $wrapper.data('settings', settings);

          if (settings.width) {
            $wrapper.css('width', settings.width);
          }

          $wrapper.html(`
            <div class="msd-header">
              <input type="text" class="msd-input"
                placeholder="${settings.placeholder}"
                autocomplete="off" spellcheck="false" />
              <div class="msd-chevron" aria-hidden="true">
                <svg width="16" height="16" viewBox="0 0 26 26">
                  <polyline points="6 12 12 18 18 12"
                    fill="none" stroke="#555" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>
                </svg>
              </div>
            </div>
            <div class="msd-content">
              <div class="msd-item-list"></div>
            </div>
          `);

          const $input = $wrapper.find('.msd-input');
          const $itemList = $wrapper.find('.msd-item-list');

          const $addSuggestion = $('<div class="msd-add-suggestion" style="display:none;"></div>')
            .prependTo($itemList);

            function updateSelected(forceTrigger = false) {
              const selected = $itemList.find('input[type="checkbox"]:checked')
                .map(function(){ return this.value; }).get();

              if (selected.length) {
                $input.val(selected.join(', '));
              } else {
                $input.val('');
              }
              $input.prop('placeholder', settings.placeholder);

              const prevSelected = $wrapper.data('selectedItems') || [];
              $wrapper.data('selectedItems', selected);

              if (settings.allowAdd) {
                $itemList.children('.msd-item').show();
              }

              if (
                (forceTrigger || prevSelected.length !== selected.length ||
                 prevSelected.some((v, i) => v !== selected[i])) &&
                 typeof settings.onChange === 'function'
              ) {
                    settings.onChange.call($wrapper, selected);
              }
          }

          function createItem(text, checked=false){
            const $container = $('<div>').addClass('msd-item');

            if (settings.allowDelete) {
              const $delete = $(`
                <button type="button" class="msd-delete">
                  <svg viewBox="0 0 10 10">
                    <line x1="2" y1="2" x2="8" y2="8"/>
                    <line x1="8" y1="2" x2="2" y2="8"/>
                  </svg>
                </button>
              `).on('click', function(e){
                e.stopPropagation();
                $container.remove();
                updateSelected(true);
              });
              $container.append($delete);
            }

            const $label = $('<label>').addClass('msd-label');
            const $checkbox = $('<input type="checkbox" style="margin: 3px 0 3px 0;">')
              .val(text)
              .prop('checked', checked)
              .on('change', function(){
                updateSelected();
              });

            $label.append($checkbox).append($('<span>').text(text));
            $container.append($label);

            $itemList.append($container);
          }

          function showDropdown(force, fromInput){
            if (!fromInput) {
              $itemList.children('.msd-item').show();
              $addSuggestion.hide();
            }
            if(!$itemList.children().length && !force) return;
            $('.msd-dropdown.msd-show').not($wrapper).removeClass('msd-open msd-show');
            $wrapper.addClass('msd-open msd-show');
          }

          function hideDropdown(){
            $wrapper.removeClass('msd-open msd-show');
            $itemList.children('.msd-item').show();
            $addSuggestion.hide();

            const selected = $wrapper.data('selectedItems') || [];
            if(selected.length){
              $input.val(selected.join(', '));
            } else {
              $input.val('');
            }
            $input.prop('placeholder', settings.placeholder);
          }

          function handleInput(){
            const query = $input.val().trim();
            const queryLower = query.toLowerCase();

            if (!query) {
              $addSuggestion.hide();
              $itemList.children('.msd-item').show();
              showDropdown(true, true);
              return;
            }

            let exactMatch = false;
            $itemList.children('.msd-item').each(function(){
              let txt = $(this).text().toLowerCase();
              let q = queryLower;

              if (settings.removeSpaces) {
                txt = txt.replace(/\s+/g, '');
                q = q.replace(/\s+/g, '');
              }

              const match = $(this).text().toLowerCase().includes(queryLower);
              $(this).toggle(match);

              if (txt === q) {
                exactMatch = true;
              }
            });

            if(settings.allowAdd && !exactMatch){
              $addSuggestion.text(`${settings.addSuggestionText} "${query}"`).show();
            } else {
              $addSuggestion.hide();
            }

            showDropdown(true, true);
          }

          function tryAddItem(val){
            if(!val) return;

            if (settings.removeSpaces) {
              val = val.replace(/\s+/g, '');
            }

            if(!val) return;

            // Проверка по регулярному выражению
            if (settings.allowedItems) {
              const regex = new RegExp(settings.allowedItems);
              if (!regex.test(val)) {
                if (settings.allowedAlert) {
                  alert(settings.allowedAlert);
                }
                return;
              }
            }

            const exists = $itemList.find('input[type="checkbox"]').toArray()
              .some(cb => {
                let existing = cb.value.toLowerCase();
                let newVal = val.toLowerCase();
                if (settings.removeSpaces) {
                  existing = existing.replace(/\s+/g, '');
                  newVal = newVal.replace(/\s+/g, '');
                }
                return existing === newVal;
              });

            if(!exists){
              createItem(val, true);
            }

            updateSelected(true);
            $input.val('');
            $input.prop('placeholder', '');
            $addSuggestion.hide();
            handleInput();
          }

          $wrapper.data('multiSelectDropdown', {
            createItem,
            updateSelected,
            $itemList,
            $input
          });

          if(settings.allowAdd){
            $input.on('input', handleInput)
              .on('keydown', function(e){
                if(e.key === 'Enter'){
                  e.preventDefault();
                  tryAddItem($input.val().trim());
                }
              })
              .on('focus', function(){
                const selected = $wrapper.data('selectedItems') || [];

                $input.prop('placeholder', '');
                if (selected.length > 0) {
                  $input.val('');
                } else {
                  if (selected.length == 0 && !settings.allowAdd)
                    $input.prop('placeholder', settings.placeholder);
                }
                showDropdown(true, false);
              });

            $addSuggestion.on('click', function(){
              tryAddItem($input.val().trim());
              $input.focus();
            });
          } else {
            $input.prop('readonly', true)
              .on('focus', function(){
                showDropdown(true, false);
              });
          }

          $(document).on('keydown', function(e){
             if(e.key === 'Escape' && $wrapper.hasClass('msd-show')){
               e.preventDefault();
               hideDropdown();
               updateSelected();
               document.activeElement.blur();
            }
          });

          $wrapper.find('.msd-chevron').on('click', function(e){
            e.stopPropagation();
            $wrapper.hasClass('msd-show') ? hideDropdown() : (showDropdown(true, false), $input.focus());
          });

          $wrapper.find('.msd-header').on('click', function(e){
            if(!$(e.target).closest('.msd-chevron').length){
              showDropdown(true, false);
              $input.focus();
            }
          });

          $(window).on('click', function(e){
            if(!$(e.target).closest($wrapper).length){
              hideDropdown();
              updateSelected();
            }
          });

          settings.items.forEach(item => {
            if(typeof item === 'string'){
              createItem(item, false);
            } else if(item && typeof item === 'object' && item.text){
              createItem(item.text, !!item.checked);
            }
          });

          updateSelected(false);
        });
      },

      getSelected: function(){
        return this.data('selectedItems') || [];
      },

      getAllItems: function(){
        const inst = this.data('multiSelectDropdown');
        if(inst){
          return inst.$itemList.find('input[type="checkbox"]').map(function(){
            return {
              text: this.value,
              checked: $(this).prop('checked')
            };
          }).get();
        }
        return [];
      },

      setSelected: function(values){
        const inst = this.data('multiSelectDropdown');
        if(inst){
          inst.$itemList.find('input[type="checkbox"]').each(function(){
            $(this).prop('checked', values.includes(this.value));
          });
          inst.updateSelected();
        }
      },

      addItem: function(text, checked){
        const inst = this.data('multiSelectDropdown');
        if(inst){
          inst.createItem(text, !!checked);
          inst.updateSelected();
        }
      },

      setPlaceholder: function(text){
        return this.each(function(){
          const settings = $(this).data('settings');
          if(settings){
            settings.placeholder = text;
          }
          const inst = $(this).data('multiSelectDropdown');
          if(inst && inst.$input){
            inst.$input.prop('placeholder', text);
          }
        });
      }
    };

    if(methods[methodOrOptions]){
      return methods[methodOrOptions].apply(this, Array.prototype.slice.call(arguments, 1));
    } else if(typeof methodOrOptions === 'object' || !methodOrOptions){
      return methods.init.apply(this, arguments);
    } else {
      $.error('Method ' + methodOrOptions + ' not found in multiSelectDropdown');
    }
  };
})(jQuery);
